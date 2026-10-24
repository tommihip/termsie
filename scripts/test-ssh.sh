#!/bin/zsh
# End-to-end checks for SSH terminals and the Option key, through the headless DebugDriver.
#
# Starts a throwaway sshd on 127.0.0.1 as the current user (no root, no Remote Login, nothing in
# ~/.ssh touched), with its own host key and authorized_keys, then points Termsie at it. Secrets
# come from a fixture file, so the Keychain is never touched either.
set -u
BIN=${1:-build/Termsie.app/Contents/MacOS/Termsie}
BIN=${BIN:A}
ROOT=$(mktemp -d)
PORT=$(( 20000 + RANDOM % 20000 ))
fail=0
ok()   { print "  ok   $1" }
bad()  { print "  FAIL $1"; fail=1 }
check(){ if [[ -n "$2" ]]; then ok "$1"; else bad "$1"; fi }

cleanup() {
  [[ -f $ROOT/sshd.pid ]] && kill $(cat $ROOT/sshd.pid) 2>/dev/null
  rm -rf $ROOT
}
trap cleanup EXIT

S=$ROOT/sshd; mkdir -p $S
ssh-keygen -q -t ed25519 -N '' -f $S/host_key
ssh-keygen -q -t ed25519 -N 'open sesame' -C termsie-test -f $S/locked_key
cp $S/locked_key $S/plain_key && ssh-keygen -q -p -P 'open sesame' -N '' -f $S/plain_key >/dev/null
cat $S/locked_key.pub > $S/authorized_keys; chmod 600 $S/authorized_keys
cat > $S/sshd_config <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $S/host_key
AuthorizedKeysFile $S/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $ROOT/sshd.pid
EOF
/usr/sbin/sshd -f $S/sshd_config -E $S/sshd.log || { print "could not start sshd"; exit 1 }
for _ in {1..20}; do ssh-keyscan -p $PORT 127.0.0.1 > $S/known_hosts 2>/dev/null && [[ -s $S/known_hosts ]] && break; sleep 0.2; done

# A workspace of SSH terminals against that server. Every connection pins the fixture
# known_hosts, so the real one is neither read nor written.
OPTS='"UserKnownHostsFile='$S/known_hosts'","StrictHostKeyChecking=yes"'
ssh_terminal() { # id, identity json, extra json
  print -r -- '{"id":"'$1'","frame":[0,0,1,1],'$3'"ssh":{"host":"127.0.0.1","port":'$PORT','$2',"options":['$OPTS']}}'
}

run_ws() { # fixture, workspace json terminals, actions
  local fix=$1 terms=$2 actions=$3
  mkdir -p $fix/termsie/workspaces
  print -r -- '{"version":2,"name":"ssh","layout":{"version":2,"terminals":['$terms']}}' > $fix/termsie/workspaces/ssh.json
  XDG_CONFIG_HOME=$fix TERMSIE_SECRETS_FILE=$fix/secrets.json \
    "$BIN" --workspace ssh --snapshot $fix/shot.png --actions "$actions" --quit 2>&1
}

print "== a key file with its passphrase from the Keychain, plus server-side folder and commands"
fix=$ROOT/keyfile; mkdir -p $fix
print '{"s-pass":"open sesame"}' > $fix/secrets.json
term=$(ssh_terminal t-key '"identity":"keyFile","identityFile":"'$S/locked_key'","passphraseRef":"s-pass"' \
  '"cwd":"/usr/share","startupCommands":["echo SSH-OK-$((6*7))","pwd"],')
out=$(run_ws $fix "$term" "wait,wait,wait,wait,wait,dumpText:1,dumpNames"); [[ -n ${TERMSIE_SHOW:-} ]] && print -r -- "$out" | grep "DebugDriver text"
check "connected and ran the startup commands on the server" "$(print -r -- "$out" | grep 'DebugDriver text: #1.*SSH-OK-42')"
check "in the folder on the server"                      "$(print -r -- "$out" | grep 'DebugDriver text: #1.*| /usr/share')"
check "the passphrase was never shown"                    "$(print -r -- "$out" | grep 'DebugDriver text: #1' | grep -v 'open sesame' | grep -v 'Enter passphrase')"
check "the terminal is named after the destination"       "$(print -r -- "$out" | grep "row=\[127.0.0.1:$PORT\]")"
check "the passphrase never reached a file Termsie wrote" "$([[ -z "$(grep -rl 'open sesame' $fix/termsie)" ]] && echo yes)"

print "\n== a private key stored in the Keychain"
private_dirs() { ls ${TMPDIR:-/tmp}/termsie-ssh 2>/dev/null | sort }
dirs_before=$(private_dirs)
fix=$ROOT/stored; mkdir -p $fix
python3 -c 'import json,sys; print(json.dumps({"s-key": open(sys.argv[1]).read()}))' $S/plain_key > $fix/secrets.json
term=$(ssh_terminal t-stored '"identity":"storedKey","privateKeyRef":"s-key"' '"startupCommands":["echo STORED-$((2+3))"],')
out=$(run_ws $fix "$term" "wait,wait,wait,wait,wait,dumpText:1")
check "connected with the stored key"                     "$(print -r -- "$out" | grep 'DebugDriver text: #1.*STORED-5')"
check "and removed its private copy afterwards"           "$([[ "$(private_dirs)" == "$dirs_before" ]] && echo yes)"
check "the key never reached a file Termsie wrote"        "$([[ -z "$(grep -rl 'PRIVATE KEY' $fix/termsie)" ]] && echo yes)"

print "\n== a wrong stored passphrase is tried once, then asked for in the terminal"
fix=$ROOT/wrong; mkdir -p $fix
print '{"s-pass":"not it"}' > $fix/secrets.json
term=$(ssh_terminal t-wrong '"identity":"keyFile","identityFile":"'$S/locked_key'","passphraseRef":"s-pass"' '')
out=$(run_ws $fix "$term" "wait,wait,wait,wait,dumpText:1,type:open sesame\n,wait,wait,wait,type:echo ASKED-OK\n,wait,wait,dumpText:1"); [[ -n ${TERMSIE_SHOW:-} ]] && print -r -- "$out" | grep "DebugDriver text"
check "the prompt appears in the terminal"                "$(print -r -- "$out" | grep 'DebugDriver text: #1.*Enter passphrase')"
check "and the typed answer logs in"                      "$(print -r -- "$out" | grep 'DebugDriver text: #1.*ASKED-OK')"

print "\n== connections that must not start"
fix=$ROOT/refused; mkdir -p $fix
print '{}' > $fix/secrets.json
mkdir -p $fix/termsie/workspaces
print -r -- '{"version":2,"name":"ssh","layout":{"version":2,"terminals":[
  {"id":"t-proxy","frame":[0,0,1,1],"ssh":{"host":"127.0.0.1","options":["ProxyCommand=touch '$fix'/pwned"]}},
  {"id":"t-dash","frame":[0,0,1,1],"ssh":{"host":"-oProxyCommand=touch '$fix'/pwned2"}}]}}' > $fix/termsie/workspaces/ssh.json
out=$(XDG_CONFIG_HOME=$fix "$BIN" --workspace ssh --snapshot $fix/shot.png --actions "wait,wait,dumpText:1,dumpText:2" --quit 2>&1)
check "a command-running option is refused"               "$(print -r -- "$out" | grep 'text: #1.*ProxyCommand is not allowed')"
check "a host that is really an option is refused"        "$(print -r -- "$out" | grep 'text: #2.*is not a valid host')"
check "and neither ran anything"                          "$([[ ! -e $fix/pwned && ! -e $fix/pwned2 ]] && echo yes)"

print "\n== Option types what the keyboard layout puts there"
fix=$ROOT/option; mkdir -p $fix/termsie
out=$(XDG_CONFIG_HOME=$fix "$BIN" --cwd $HOME --snapshot $fix/shot.png --quit \
  --actions "wait,optionKey:@|2,optionKey:{|8,optionKey:∫|b,optionKey:ƒ|f" 2>&1)
check "Finnish ⌥2 types @"                                "$(print -r -- "$out" | grep 'optionKey: \[@\] meta=false')"
check "⌥⇧8 types {"                                       "$(print -r -- "$out" | grep 'optionKey: \[{\] meta=false')"
check "US ⌥B is still Meta-B"                             "$(print -r -- "$out" | grep 'optionKey: \[∫\] meta=true')"
check "US ⌥F is still Meta-F"                             "$(print -r -- "$out" | grep 'optionKey: \[ƒ\] meta=true')"
print '{"optionAsMeta":false}' > $fix/termsie/config.json
out=$(XDG_CONFIG_HOME=$fix "$BIN" --cwd $HOME --snapshot $fix/shot.png --quit --actions "wait,optionKey:∫|b" 2>&1)
check "optionAsMeta off turns Meta off everywhere"        "$(print -r -- "$out" | grep 'optionKey: \[∫\] meta=false')"

print ""
if (( fail )); then print "SSH TESTS FAILED"; print "sshd log:"; tail -20 $S/sshd.log; exit 1; else print "all ssh tests passed"; fi
