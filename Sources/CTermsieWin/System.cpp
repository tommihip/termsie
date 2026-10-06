// Process setup, processes, the credential store, the clipboard, shell integration, file dialogs,
// and file integrity checks.

#include <windows.h>

#include "CTermsieWin.h"

#include <shellapi.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <commctrl.h>
#include <tlhelp32.h>
#include <wincred.h>
#include <bcrypt.h>
#include <softpub.h>
#include <wintrust.h>
#include <dwmapi.h>
#include <imm.h>
#include <stdlib.h>
#include <string.h>
#include <string>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "wintrust.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "imm32.lib")

extern "C" {

void tw_process_init(void) {
    // Per-monitor v2 makes Windows send WM_DPICHANGED and scale non-client areas itself; the
    // client area is drawn at the monitor's real DPI by the renderer.
    typedef BOOL(WINAPI * SetContextFn)(HANDLE);
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32) {
        auto set = (SetContextFn)GetProcAddress(user32, "SetProcessDpiAwarenessContext");
        if (set) set((HANDLE)-4 /* DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 */);
    }
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES | ICC_TAB_CLASSES |
                                                 ICC_LISTVIEW_CLASSES | ICC_UPDOWN_CLASS};
    InitCommonControlsEx(&icc);
    // Groups every Termsie window under one taskbar button, also for the copy the updater swaps in.
    SetCurrentProcessExplicitAppUserModelID(L"Termsie.Termsie");
}

DWORD tw_windows_build(void) {
    typedef LONG(WINAPI * RtlGetVersionFn)(OSVERSIONINFOW *);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    if (!ntdll) return 0;
    auto get = (RtlGetVersionFn)GetProcAddress(ntdll, "RtlGetVersion");
    if (!get) return 0;
    OSVERSIONINFOW info = {};
    info.dwOSVersionInfoSize = sizeof(info);
    if (get(&info) != 0) return 0;
    return info.dwBuildNumber;
}

// ------------------------------------------------------------------------------------- window

int tw_window_set_appearance(TWWindowHandle hwnd_handle, int dark, int backdrop) {
    HWND hwnd = (HWND)hwnd_handle;
    if (!hwnd) return 0;
    BOOL useDark = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, &useDark, sizeof(useDark));
    if (!backdrop || tw_windows_build() < 22621) return 0;
    // DWMWA_SYSTEMBACKDROP_TYPE = 38, DWMSBT_TRANSIENTWINDOW (acrylic) = 3.
    int type = 3;
    if (FAILED(DwmSetWindowAttribute(hwnd, 38, &type, sizeof(type)))) return 0;
    MARGINS margins = {-1, -1, -1, -1};
    DwmExtendFrameIntoClientArea(hwnd, &margins);
    return 1;
}

void tw_window_set_icon(TWWindowHandle hwnd_handle, const wchar_t *icoPath) {
    HWND hwnd = (HWND)hwnd_handle;
    if (!hwnd) return;
    HINSTANCE module = GetModuleHandleW(nullptr);
    HICON big = (HICON)LoadImageW(module, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                                  GetSystemMetrics(SM_CYICON), 0);
    HICON smallIcon = (HICON)LoadImageW(module, MAKEINTRESOURCEW(1), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                    GetSystemMetrics(SM_CYSMICON), 0);
    if (!big && icoPath) {
        big = (HICON)LoadImageW(nullptr, icoPath, IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                                GetSystemMetrics(SM_CYICON), LR_LOADFROMFILE);
        smallIcon = (HICON)LoadImageW(nullptr, icoPath, IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                  GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE);
    }
    if (big) SendMessageW(hwnd, WM_SETICON, ICON_BIG, (LPARAM)big);
    if (smallIcon) SendMessageW(hwnd, WM_SETICON, ICON_SMALL, (LPARAM)smallIcon);
}

void tw_ime_set_position(TWWindowHandle hwnd_handle, int x, int y, int lineHeight) {
    HWND hwnd = (HWND)hwnd_handle;
    if (!hwnd) return;
    HIMC imc = ImmGetContext(hwnd);
    if (!imc) return;
    COMPOSITIONFORM form = {};
    form.dwStyle = CFS_POINT;
    form.ptCurrentPos.x = x;
    form.ptCurrentPos.y = y;
    ImmSetCompositionWindow(imc, &form);
    CANDIDATEFORM candidate = {};
    candidate.dwIndex = 0;
    candidate.dwStyle = CFS_EXCLUDE;
    candidate.ptCurrentPos.x = x;
    candidate.ptCurrentPos.y = y;
    candidate.rcArea = {x, y, x + 1, y + lineHeight};
    ImmSetCandidateWindow(imc, &candidate);
    ImmReleaseContext(hwnd, imc);
}

int tw_track_menu(TWWindowHandle owner_handle, TWMenuHandle menu_handle, int x, int y) {
    HWND owner = (HWND)owner_handle;
    HMENU menu = (HMENU)menu_handle;
    if (!menu) return 0;
    // The owner must be foreground or the menu will not close when the user clicks elsewhere.
    SetForegroundWindow(owner);
    int chosen = (int)TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, x, y, 0, owner, nullptr);
    PostMessageW(owner, WM_NULL, 0, 0);
    return chosen;
}

void tw_menus_use_dark_mode(int dark) {
    // uxtheme ordinal 135 is SetPreferredAppMode (2 = force dark, 3 = force light) and 136 is
    // FlushMenuThemes. Undocumented but stable since Windows 10 1903, and absent harmlessly
    // before it.
    HMODULE uxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!uxtheme) return;
    typedef int(WINAPI * SetModeFn)(int);
    typedef void(WINAPI * FlushFn)(void);
    auto setMode = (SetModeFn)GetProcAddress(uxtheme, MAKEINTRESOURCEA(135));
    auto flush = (FlushFn)GetProcAddress(uxtheme, MAKEINTRESOURCEA(136));
    if (setMode && tw_windows_build() >= 18362) setMode(dark ? 2 : 3);
    if (flush) flush();
}

// ---------------------------------------------------------------------------------- processes

int tw_list_processes(TWProcessInfo *out, int capacity) {
    if (!out || capacity <= 0) return 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W entry = {};
    entry.dwSize = sizeof(entry);
    int count = 0;
    if (Process32FirstW(snap, &entry)) {
        do {
            TWProcessInfo &info = out[count++];
            info.pid = entry.th32ProcessID;
            info.parentPid = entry.th32ParentProcessID;
            wcsncpy_s(info.name, MAX_PATH, entry.szExeFile, _TRUNCATE);
        } while (count < capacity && Process32NextW(snap, &entry));
    }
    CloseHandle(snap);
    return count;
}

int tw_process_image_path(DWORD pid, wchar_t *out, int capacity) {
    if (!out || capacity <= 0) return 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    DWORD size = (DWORD)capacity;
    int result = QueryFullProcessImageNameW(h, 0, out, &size) ? (int)size : 0;
    CloseHandle(h);
    return result;
}

typedef struct {
    USHORT Length;
    USHORT MaximumLength;
    PWSTR Buffer;
} TW_UNICODE_STRING;

int tw_process_command_line(DWORD pid, wchar_t *out, int capacity) {
    if (!out || capacity <= 0) return 0;
    typedef LONG(WINAPI * QueryFn)(HANDLE, ULONG, PVOID, ULONG, PULONG);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    auto query = ntdll ? (QueryFn)GetProcAddress(ntdll, "NtQueryInformationProcess") : nullptr;
    if (!query) return 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    int result = 0;
    ULONG needed = 0;
    const ULONG ProcessCommandLineInformation = 60;
    query(h, ProcessCommandLineInformation, nullptr, 0, &needed);
    if (needed > 0 && needed < 1 << 20) {
        void *buffer = malloc(needed);
        if (buffer && query(h, ProcessCommandLineInformation, buffer, needed, &needed) >= 0) {
            auto str = (TW_UNICODE_STRING *)buffer;
            int chars = str->Length / sizeof(wchar_t);
            if (chars >= capacity) chars = capacity - 1;
            wmemcpy(out, str->Buffer, chars);
            out[chars] = 0;
            result = chars;
        }
        free(buffer);
    }
    CloseHandle(h);
    return result;
}

// ----------------------------------------------------------------------------------- secrets

int tw_cred_write(const wchar_t *target, const wchar_t *comment, const void *blob, DWORD length) {
    if (!target) return 0;
    CREDENTIALW cred = {};
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = (LPWSTR)target;
    cred.Comment = (LPWSTR)comment;
    cred.CredentialBlobSize = length;
    cred.CredentialBlob = (LPBYTE)blob;
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    cred.UserName = (LPWSTR)L"Termsie";
    return CredWriteW(&cred, 0) ? 1 : 0;
}

int tw_cred_read(const wchar_t *target, void **blob) {
    if (!target || !blob) return -1;
    PCREDENTIALW cred = nullptr;
    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &cred)) return -1;
    int length = (int)cred->CredentialBlobSize;
    void *copy = malloc(length > 0 ? length : 1);
    if (copy && length > 0) memcpy(copy, cred->CredentialBlob, length);
    CredFree(cred);
    *blob = copy;
    return copy ? length : -1;
}

int tw_cred_delete(const wchar_t *target) {
    if (!target) return 0;
    return CredDeleteW(target, CRED_TYPE_GENERIC, 0) ? 1 : 0;
}

// --------------------------------------------------------------------------------- clipboard

static BOOL openClipboard(HWND owner) {
    // Another process can hold the clipboard for a moment; a short retry beats a lost copy.
    for (int attempt = 0; attempt < 10; attempt++) {
        if (OpenClipboard(owner)) return TRUE;
        Sleep(10);
    }
    return FALSE;
}

int tw_clipboard_set_text(TWWindowHandle owner_handle, const wchar_t *text, int len) {
    HWND owner = (HWND)owner_handle;
    if (!text || len < 0) return 0;
    if (!openClipboard(owner)) return 0;
    EmptyClipboard();
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, ((SIZE_T)len + 1) * sizeof(wchar_t));
    int ok = 0;
    if (mem) {
        wchar_t *dst = (wchar_t *)GlobalLock(mem);
        if (dst) {
            wmemcpy(dst, text, len);
            dst[len] = 0;
            GlobalUnlock(mem);
            ok = SetClipboardData(CF_UNICODETEXT, mem) != nullptr;
        }
        if (!ok) GlobalFree(mem);
    }
    CloseClipboard();
    return ok;
}

wchar_t *tw_clipboard_get_text(TWWindowHandle owner_handle) {
    HWND owner = (HWND)owner_handle;
    if (!openClipboard(owner)) return nullptr;
    wchar_t *result = nullptr;
    HANDLE data = GetClipboardData(CF_UNICODETEXT);
    if (data) {
        const wchar_t *src = (const wchar_t *)GlobalLock(data);
        if (src) {
            size_t len = wcslen(src);
            result = (wchar_t *)malloc((len + 1) * sizeof(wchar_t));
            if (result) wmemcpy(result, src, len + 1);
            GlobalUnlock(data);
        }
    }
    CloseClipboard();
    return result;
}

void tw_free(void *p) { free(p); }

// ------------------------------------------------------------------------------------- shell

int tw_spawn_detached(const wchar_t *commandLine) {
    if (!commandLine) return 0;
    std::wstring cmd(commandLine);
    STARTUPINFOW si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};
    BOOL ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE,
                             CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB,
                             nullptr, nullptr, &si, &pi);
    if (!ok) {
        // Breaking away from a job is refused inside some job objects; try without.
        ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
                            nullptr, nullptr, &si, &pi);
    }
    if (!ok) return 0;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 1;
}

int tw_shell_open(const wchar_t *target) {
    if (!target) return 0;
    return (INT_PTR)ShellExecuteW(nullptr, L"open", target, nullptr, nullptr, SW_SHOWNORMAL) > 32;
}

int tw_shell_reveal(const wchar_t *folder, const wchar_t *file) {
    if (!folder) return 0;
    if (!file) return tw_shell_open(folder);
    std::wstring args = L"/select,\"";
    args += folder;
    if (!args.empty() && args.back() != L'\\') args += L'\\';
    args += file;
    args += L"\"";
    return (INT_PTR)ShellExecuteW(nullptr, L"open", L"explorer.exe", args.c_str(), nullptr, SW_SHOWNORMAL) > 32;
}

int tw_file_dialog(TWWindowHandle owner_handle, int save, int pickFolder, const wchar_t *title, const wchar_t *filterName,
                   const wchar_t *filterSpec, const wchar_t *defaultName, const wchar_t *defaultExtension,
                   const wchar_t *initialFolder, wchar_t *out, int capacity) {
    HWND owner = (HWND)owner_handle;
    if (!out || capacity <= 0) return 0;
    IFileDialog *dialog = nullptr;
    HRESULT hr = CoCreateInstance(save ? CLSID_FileSaveDialog : CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                                  save ? IID_IFileSaveDialog : IID_IFileOpenDialog, (void **)&dialog);
    if (FAILED(hr) || !dialog) return 0;
    DWORD options = 0;
    dialog->GetOptions(&options);
    options |= FOS_FORCEFILESYSTEM;
    if (pickFolder) options |= FOS_PICKFOLDERS;
    if (save) options |= FOS_OVERWRITEPROMPT;
    dialog->SetOptions(options);
    if (title) dialog->SetTitle(title);
    if (filterName && filterSpec && !pickFolder) {
        COMDLG_FILTERSPEC spec[2] = {{filterName, filterSpec}, {L"All files", L"*.*"}};
        dialog->SetFileTypes(2, spec);
    }
    if (defaultExtension) dialog->SetDefaultExtension(defaultExtension);
    if (defaultName) dialog->SetFileName(defaultName);
    if (initialFolder) {
        IShellItem *folder = nullptr;
        if (SUCCEEDED(SHCreateItemFromParsingName(initialFolder, nullptr, IID_IShellItem, (void **)&folder)) && folder) {
            dialog->SetFolder(folder);
            folder->Release();
        }
    }
    int result = 0;
    if (SUCCEEDED(dialog->Show(owner))) {
        IShellItem *item = nullptr;
        if (SUCCEEDED(dialog->GetResult(&item)) && item) {
            PWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
                wcsncpy_s(out, capacity, path, _TRUNCATE);
                CoTaskMemFree(path);
                result = 1;
            }
            item->Release();
        }
    }
    dialog->Release();
    return result;
}

// --------------------------------------------------------------------------------- integrity

int tw_sha256_file(const wchar_t *path, uint8_t out[32]) {
    if (!path || !out) return 0;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file == INVALID_HANDLE_VALUE) return 0;
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    int ok = 0;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) == 0 &&
        BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0) == 0) {
        static unsigned char buffer[1 << 16];
        DWORD got = 0;
        ok = 1;
        while (ReadFile(file, buffer, sizeof(buffer), &got, nullptr) && got > 0) {
            if (BCryptHashData(hash, buffer, got, 0) != 0) { ok = 0; break; }
        }
        if (ok) ok = BCryptFinishHash(hash, out, 32, 0) == 0;
    }
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    CloseHandle(file);
    return ok;
}

int tw_verify_signature(const wchar_t *path, wchar_t *signer, int capacity) {
    if (!path) return 0;
    WINTRUST_FILE_INFO fileInfo = {};
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = path;
    GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    WINTRUST_DATA data = {};
    data.cbStruct = sizeof(data);
    data.dwUIChoice = WTD_UI_NONE;
    data.fdwRevocationChecks = WTD_REVOKE_NONE;
    data.dwUnionChoice = WTD_CHOICE_FILE;
    data.pFile = &fileInfo;
    data.dwStateAction = WTD_STATEACTION_VERIFY;
    LONG status = WinVerifyTrust((HWND)INVALID_HANDLE_VALUE, &action, &data);
    int ok = status == ERROR_SUCCESS;
    if (ok && signer && capacity > 0) {
        signer[0] = 0;
        CRYPT_PROVIDER_DATA *prov = WTHelperProvDataFromStateData(data.hWVTStateData);
        CRYPT_PROVIDER_SGNR *sgnr = prov ? WTHelperGetProvSignerFromChain(prov, 0, FALSE, 0) : nullptr;
        if (sgnr && sgnr->csCertChain > 0 && sgnr->pasCertChain && sgnr->pasCertChain[0].pCert) {
            CertGetNameStringW(sgnr->pasCertChain[0].pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, signer,
                               (DWORD)capacity);
        }
    }
    data.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust((HWND)INVALID_HANDLE_VALUE, &action, &data);
    return ok;
}

}  // extern "C"
