#!/bin/sh
# Runs in the container's VM, outside the container: lib\agent-patch.ps1 starts it with
# vctl execvm, through /proc/<pid>/root of a container process. See agent-patch.cjs.
# Prints RESULT lines. The last one is the outcome: patched, already-patched,
# error <reason>, or a retryable not-ready or busy.
AGENT=/usr/lib/vmware/spherelet/bin/spherelet-spagent
START=$((0x138bc30))
END=$((START + 23))

# Prints the lowest pid whose /proc folder passes the test $1.
oldest() {
	o=
	for d in /proc/[0-9]*; do
		if $1 $d; then
			p=${d#/proc/}
			if [ -z "$o" ] || [ $p -lt $o ]; then o=$p; fi
		fi
	done
	echo $o
}
in_container() { [ -e $1/root/opt/pi-vctl/agent-patch.cjs ]; }
# By executable, not name: runc's init can briefly share the agent's command line.
is_agent() { [ $1/exe -ef $AGENT ]; }

# The container's oldest process, so its root stays valid while this runs.
P=$(oldest in_container)
A=$(oldest is_agent)
if [ -z "$P" ]; then echo "RESULT not-ready"; exit 0; fi
if [ -z "$A" ]; then echo "RESULT error no-agent"; exit 0; fi
R=/proc/$P/root
echo "RESULT agent=$A container=$P"

v=$(chroot $R /usr/local/bin/node /opt/pi-vctl/agent-patch.cjs verify 4<$AGENT 2>&1)
if [ "$v" != verified ]; then echo "RESULT $v"; exit 0; fi

all_stopped() {
	for t in /proc/$A/task/*; do
		read -r st < $t/stat
		case ${st#*) } in T*|t*) ;; *) return 1 ;; esac
	done
}
# A thread exactly at START is fine: it runs the new code.
none_inside() {
	for t in /proc/$A/task/*; do
		read -r sc < $t/syscall
		pc=${sc##* }
		case $pc in 0x*) ;; *) return 1 ;; esac
		if [ $((pc)) -gt $START ] && [ $((pc)) -lt $END ]; then return 1; fi
	done
}

# Never leave the agent stopped: it carries the terminal.
trap 'kill -CONT $A 2>/dev/null' EXIT
trap 'exit 1' HUP INT TERM

# Pause the agent while none of its threads is partway through the bytes being replaced.
kill -STOP $A
tries=0
until all_stopped && none_inside; do
	tries=$((tries + 1))
	if [ $tries -ge 100 ]; then echo "RESULT busy"; exit 0; fi
	kill -CONT $A
	sleep 0.01
	kill -STOP $A
	sleep 0.01
done

echo "RESULT $(chroot $R /usr/local/bin/node /opt/pi-vctl/agent-patch.cjs patch 3<>/proc/$A/mem 2>&1)"
