// The Windows pseudo console (ConPTY): a shell attached to a console that has no window, whose
// screen arrives as a VT byte stream on a pipe and whose keyboard is a pipe the other way.
//
// A `conpty.dll` shipped next to the executable is preferred over the one in Windows. The
// in-box ConPTY on older Windows 10 builds mishandles several sequences; Microsoft publishes the
// current one (the same that Windows Terminal ships) as a redistributable.

#include <windows.h>

#include "CTermsieWin.h"

#include <stdlib.h>
#include <string>

typedef HRESULT(WINAPI *CreatePseudoConsoleFn)(COORD, HANDLE, HANDLE, DWORD, HPCON *);
typedef HRESULT(WINAPI *ResizePseudoConsoleFn)(HPCON, COORD);
typedef void(WINAPI *ClosePseudoConsoleFn)(HPCON);

struct ConptyApi {
    CreatePseudoConsoleFn create = nullptr;
    ResizePseudoConsoleFn resize = nullptr;
    ClosePseudoConsoleFn close = nullptr;
};

static ConptyApi loadApi() {
    ConptyApi api;
    wchar_t exe[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
    if (n > 0 && n < MAX_PATH) {
        std::wstring dir(exe, n);
        size_t slash = dir.find_last_of(L'\\');
        if (slash != std::wstring::npos) {
            std::wstring dll = dir.substr(0, slash) + L"\\conpty.dll";
            if (GetFileAttributesW(dll.c_str()) != INVALID_FILE_ATTRIBUTES) {
                HMODULE m = LoadLibraryExW(dll.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
                if (m) {
                    api.create = (CreatePseudoConsoleFn)GetProcAddress(m, "ConptyCreatePseudoConsole");
                    api.resize = (ResizePseudoConsoleFn)GetProcAddress(m, "ConptyResizePseudoConsole");
                    api.close = (ClosePseudoConsoleFn)GetProcAddress(m, "ConptyClosePseudoConsole");
                    if (api.create && api.resize && api.close) return api;
                }
            }
        }
    }
    HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
    api.create = (CreatePseudoConsoleFn)GetProcAddress(kernel, "CreatePseudoConsole");
    api.resize = (ResizePseudoConsoleFn)GetProcAddress(kernel, "ResizePseudoConsole");
    api.close = (ClosePseudoConsoleFn)GetProcAddress(kernel, "ClosePseudoConsole");
    return api;
}

static const ConptyApi &conpty() {
    static ConptyApi api = loadApi();
    return api;
}

struct TWPty {
    HPCON console = nullptr;
    HANDLE input = nullptr;   // we write keystrokes here
    HANDLE output = nullptr;  // we read the screen from here
    PROCESS_INFORMATION process = {};
    LPPROC_THREAD_ATTRIBUTE_LIST attributes = nullptr;
    volatile LONG closed = 0;
};

extern "C" {

TWPty *tw_pty_spawn(const wchar_t *commandLine, const wchar_t *cwd, const wchar_t *environment,
                    short cols, short rows, DWORD *error) {
    DWORD dummy = 0;
    if (!error) error = &dummy;
    *error = 0;
    const ConptyApi &api = conpty();
    if (!api.create || !commandLine) {
        *error = ERROR_NOT_SUPPORTED;
        return nullptr;
    }

    HANDLE inRead = nullptr, inWrite = nullptr, outRead = nullptr, outWrite = nullptr;
    if (!CreatePipe(&inRead, &inWrite, nullptr, 0) || !CreatePipe(&outRead, &outWrite, nullptr, 0)) {
        *error = GetLastError();
        if (inRead) CloseHandle(inRead);
        if (inWrite) CloseHandle(inWrite);
        return nullptr;
    }

    TWPty *p = new TWPty();
    COORD size = {static_cast<SHORT>(cols > 0 ? cols : 80), static_cast<SHORT>(rows > 0 ? rows : 24)};
    // PSEUDOCONSOLE_INHERIT_CURSOR: the console asks the terminal where its cursor is (DSR 6)
    // and starts drawing there, rather than clearing the screen. That is what keeps output a
    // terminal restored from its last session on screen, and it is how Windows Terminal starts
    // its consoles too. The terminal answers the question itself.
    const DWORD PSEUDOCONSOLE_INHERIT_CURSOR_FLAG = 0x1;
    HRESULT hr = api.create(size, inRead, outWrite, PSEUDOCONSOLE_INHERIT_CURSOR_FLAG, &p->console);
    // The console holds its own duplicates; ours would keep the pipes open after it exits.
    CloseHandle(inRead);
    CloseHandle(outWrite);
    if (FAILED(hr)) {
        *error = (DWORD)hr;
        CloseHandle(inWrite);
        CloseHandle(outRead);
        delete p;
        return nullptr;
    }
    p->input = inWrite;
    p->output = outRead;

    SIZE_T attrSize = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attrSize);
    p->attributes = (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0, attrSize);
    if (!p->attributes || !InitializeProcThreadAttributeList(p->attributes, 1, 0, &attrSize) ||
        !UpdateProcThreadAttribute(p->attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, p->console,
                                   sizeof(HPCON), nullptr, nullptr)) {
        *error = GetLastError();
        tw_pty_close(p);
        tw_pty_free(p);
        return nullptr;
    }

    STARTUPINFOEXW si = {};
    si.StartupInfo.cb = sizeof(si);
    // Without this a child inherits Termsie's own standard handles when those are redirected (a
    // test run with captured output), and writes there instead of to the pseudo console.
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.lpAttributeList = p->attributes;

    std::wstring cmd(commandLine);  // CreateProcessW may write to its command line
    BOOL ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE,
                             EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                             (LPVOID)environment, cwd, &si.StartupInfo, &p->process);
    if (!ok) {
        *error = GetLastError();
        tw_pty_close(p);
        tw_pty_free(p);
        return nullptr;
    }
    return p;
}

int tw_pty_read(TWPty *p, void *buffer, DWORD capacity) {
    if (!p || !buffer || capacity == 0) return 0;
    DWORD got = 0;
    if (!ReadFile(p->output, buffer, capacity, &got, nullptr)) return 0;
    return (int)got;
}

int tw_pty_write(TWPty *p, const void *data, DWORD length) {
    if (!p || !data || p->closed) return 0;
    const char *bytes = (const char *)data;
    while (length > 0) {
        DWORD written = 0;
        if (!WriteFile(p->input, bytes, length, &written, nullptr) || written == 0) return 0;
        bytes += written;
        length -= written;
    }
    return 1;
}

void tw_pty_resize(TWPty *p, short cols, short rows) {
    if (!p || p->closed || cols <= 0 || rows <= 0) return;
    COORD size = {cols, rows};
    conpty().resize(p->console, size);
}

DWORD tw_pty_pid(TWPty *p) { return p ? p->process.dwProcessId : 0; }

int tw_pty_wait(TWPty *p, DWORD timeoutMs, DWORD *exitCode) {
    if (!p || !p->process.hProcess) return 1;
    if (WaitForSingleObject(p->process.hProcess, timeoutMs) != WAIT_OBJECT_0) return 0;
    DWORD code = 0;
    GetExitCodeProcess(p->process.hProcess, &code);
    if (exitCode) *exitCode = code;
    return 1;
}

void tw_pty_close(TWPty *p) {
    if (!p) return;
    if (InterlockedExchange(&p->closed, 1) != 0) return;
    // Closing the console ends every program attached to it and, once its last output is
    // written, the output pipe, which is what lets the reader finish.
    if (p->console) conpty().close(p->console);
    if (p->input) {
        CloseHandle(p->input);
        p->input = nullptr;
    }
}

void tw_pty_terminate(TWPty *p) {
    if (!p) return;
    if (p->process.hProcess) TerminateProcess(p->process.hProcess, 1);
    tw_pty_close(p);
}

void tw_pty_free(TWPty *p) {
    if (!p) return;
    tw_pty_close(p);
    if (p->output) CloseHandle(p->output);
    if (p->process.hThread) CloseHandle(p->process.hThread);
    if (p->process.hProcess) CloseHandle(p->process.hProcess);
    if (p->attributes) {
        DeleteProcThreadAttributeList(p->attributes);
        HeapFree(GetProcessHeap(), 0, p->attributes);
    }
    delete p;
}

}  // extern "C"
