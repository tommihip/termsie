#!/bin/zsh
# Proves the zsh shim does not change the user's shell environment.
#
# The trap this guards against: setting ZDOTDIR makes zsh skip ~/.zshenv entirely, so a naive
# shim silently drops whatever that file does — commonly the user's PATH.
set -u
BIN=${1:-build/Termsie.app/Contents/MacOS/Termsie}
FIX=$(mktemp -d)
trap "rm -rf $FIX" EXIT
fail=0
check() { if [[ "$2" == "$3" ]]; then print "  ok   $1"; else print "  FAIL $1\n       expected: $3\n       actual:   $2"; fail=1; fi }
contains() { if [[ "$2" == *"$3"* ]]; then print "  ok   $1"; else print "  FAIL $1 (missing '$3' in '$2')"; fail=1; fi }

mkdir -p $FIX/shim
"$BIN" --emit-shim $FIX/shim >/dev/null || { print "could not emit shim"; exit 1 }

run_case() {
  local label=$1 zshenv_body=$2 zshrc_body=$3 flags=$4
  print "\n== $label"
  print -r -- "$zshenv_body" > $FIX/.zshenv
  print -r -- "$zshrc_body"  > $FIX/.zshrc
  rm -f $FIX/shim/.zsh_history $FIX/hist
  local probe='print -r -- "HISTFILE=$HISTFILE|ZDOTDIR=[${ZDOTDIR-UNSET}]|MARK=${TERMSIE_TEST_MARK-none}|OMZ=${OMZ_RAN-none}"'

  local native shimmed
  native=$(env -i HOME=$FIX TERM=xterm PATH=/usr/bin:/bin /bin/zsh $flags -c "$probe" 2>/dev/null)
  shimmed=$(env -i HOME=$FIX TERM=xterm PATH=/usr/bin:/bin \
      ZDOTDIR=$FIX/shim TERMSIE_HISTFILE=$FIX/hist TERMSIE_PANE_ID=t1 \
      /bin/zsh $flags -c "$probe" 2>/dev/null)

  contains "user .zshenv ran (native)"  "$native"  "MARK=yes"
  contains "user .zshenv ran (shimmed)" "$shimmed" "MARK=yes"
  contains "user .zshrc ran (native)"   "$native"  "OMZ=1"
  contains "user .zshrc ran (shimmed)"  "$shimmed" "OMZ=1"
  contains "ZDOTDIR restored"           "$shimmed" "ZDOTDIR=[UNSET]"
  contains "HISTFILE pinned"            "$shimmed" "HISTFILE=$FIX/hist"
  # The user's own rc pointed HISTFILE at the shared file; the shim must beat it.
  contains "native HISTFILE untouched"  "$native"  "HISTFILE=$FIX/.zsh_history"

  # The strongest form: the exported environment must differ only by the variables this feature
  # is supposed to change. HISTFILE is excluded because pinning it IS the feature; it is asserted
  # separately above.
  local ne se
  ne=$(env -i HOME=$FIX TERM=xterm PATH=/usr/bin:/bin /bin/zsh $flags -c 'typeset -x | sort' 2>/dev/null | grep -v '^TERMSIE_\|^ZDOTDIR\|^HISTFILE')
  se=$(env -i HOME=$FIX TERM=xterm PATH=/usr/bin:/bin ZDOTDIR=$FIX/shim TERMSIE_HISTFILE=$FIX/hist TERMSIE_PANE_ID=t1 \
       /bin/zsh $flags -c 'typeset -x | sort' 2>/dev/null | grep -v '^TERMSIE_\|^ZDOTDIR\|^HISTFILE')
  if [[ "$ne" == "$se" ]]; then print "  ok   exported environment identical"
  else print "  FAIL exported environment differs:"; diff <(print -r -- "$ne") <(print -r -- "$se") | head -10; fail=1; fi
}

ZSHENV_NORMAL='export TERMSIE_TEST_MARK=yes
export PATH="/zshenv-marker:$PATH"'
# Simulates oh-my-zsh, which assigns HISTFILE while .zshrc runs.
ZSHRC_OMZ='export HISTFILE="$HOME/.zsh_history"
export OMZ_RAN=1'

run_case "login + interactive (Termsie default)" "$ZSHENV_NORMAL" "$ZSHRC_OMZ" "-li"
run_case "interactive only"                      "$ZSHENV_NORMAL" "$ZSHRC_OMZ" "-i"
run_case "user disables global rcs"              "unsetopt GLOBAL_RCS
$ZSHENV_NORMAL" "$ZSHRC_OMZ" "-li"

print "\n== history isolation (real ptys via expect)"
cat > $FIX/iso.exp <<'EXP'
set timeout 10
set fix [lindex $argv 0]
spawn env -i HOME=$fix TERM=xterm PATH=/usr/bin:/bin ZDOTDIR=$fix/shim TERMSIE_HISTFILE=$fix/hA TERMSIE_PANE_ID=a /bin/zsh -li
expect -re {[%$#>] $}
send "echo AAAMARKER\r"
expect "AAAMARKER"
send "exit\r"
expect eof
spawn env -i HOME=$fix TERM=xterm PATH=/usr/bin:/bin ZDOTDIR=$fix/shim TERMSIE_HISTFILE=$fix/hB TERMSIE_PANE_ID=b /bin/zsh -li
expect -re {[%$#>] $}
send "\033\[A"
sleep 1
send "\r"
expect {
  "AAAMARKER" { puts "\nRECALLED_A"; exit 1 }
  timeout {}
  -re {[%$#>] $} {}
}
send "echo BBBMARKER\r"
expect "BBBMARKER"
send "exit\r"
expect eof
exit 0
EXP
print -r -- "$ZSHENV_NORMAL" > $FIX/.zshenv
print -r -- "$ZSHRC_OMZ" > $FIX/.zshrc
if /usr/bin/expect -f $FIX/iso.exp $FIX >/dev/null 2>&1; then
  print "  ok   terminal B did not recall terminal A's command"
else
  print "  FAIL terminal B recalled terminal A's command"; fail=1
fi
if [[ -f $FIX/hA ]] && grep -q AAAMARKER $FIX/hA; then print "  ok   A's command in A's history"; else print "  FAIL A's history missing"; fail=1; fi
if [[ -f $FIX/hB ]] && ! grep -q AAAMARKER $FIX/hB; then print "  ok   A's command absent from B's history"; else print "  FAIL A leaked into B"; fail=1; fi
if [[ -f $FIX/hB ]] && grep -q BBBMARKER $FIX/hB; then print "  ok   B's command in B's history"; else print "  FAIL B's history missing"; fail=1; fi

print ""
if (( fail )); then print "SHIM TESTS FAILED"; exit 1; else print "all shim tests passed"; fi
