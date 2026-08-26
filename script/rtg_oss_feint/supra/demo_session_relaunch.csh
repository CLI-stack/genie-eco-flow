#!/bin/csh -f
#
# Demo script to simulate session timeout and relaunch behavior
# Usage: csh demo_session_relaunch.csh [session_num] [elapsed_time] [demo_dir]
#

set session_num = 1
set elapsed_time = 0
set demo_dir = "/tmp/demo_session_relaunch"

if ($#argv >= 1) then
    set session_num = $1
endif

if ($#argv >= 2) then
    set elapsed_time = $2
endif

if ($#argv >= 3) then
    set demo_dir = $3
endif

# Configuration
set session_timeout = 60      # 60 seconds per session
set target_completion = 180   # Target "completes" after 180 seconds total
set check_interval = 10       # Check every 10 seconds
set demo_script = `readlink -f $0`
set demo_log = "${demo_dir}/demo.log"

# Create demo directory if first session
if ($session_num == 1) then
    mkdir -p $demo_dir
    set now = `date`
    echo "========================================" > $demo_log
    echo "Demo started at $now" >> $demo_log
    echo "Target completion time: ${target_completion}s" >> $demo_log
    echo "Session timeout: ${session_timeout}s" >> $demo_log
    echo "========================================" >> $demo_log
    echo ""
endif

echo ""
echo "========================================"
echo "SESSION $session_num STARTED"
echo "========================================"
echo "Demo directory: $demo_dir"
echo "Previous elapsed time: ${elapsed_time}s"
echo "Session timeout: ${session_timeout}s"
echo "Target completes at: ${target_completion}s"
echo ""

set session_elapsed = 0
set target_done = 0
set session_relaunched = 0
set target_success = 0

while ($target_done == 0)
    set now = `date`
    echo "[$now] Session $session_num : elapsed=${elapsed_time}s, session_elapsed=${session_elapsed}s"

    # Check if target is "complete"
    if ($elapsed_time >= $target_completion) then
        echo ""
        echo "========================================"
        echo "TARGET COMPLETED after ${elapsed_time}s"
        echo "========================================"
        set target_done = 1
        set target_success = 1
        set now = `date`
        echo "" >> $demo_log
        echo "[$now] TARGET COMPLETED after ${elapsed_time}s in $session_num sessions" >> $demo_log
        break
    endif

    # Check if session timeout reached
    if ($session_elapsed >= $session_timeout) then
        echo ""
        echo "========================================"
        echo "Session timeout reached (${session_elapsed}s)"
        echo "Total elapsed time: ${elapsed_time}s"
        echo "Relaunching session..."
        echo "========================================"

        @ next_session = $session_num + 1
        set next_elapsed = $elapsed_time

        set now = `date`
        echo "" >> $demo_log
        echo "[$now] Session $session_num ended at ${session_elapsed}s, total ${elapsed_time}s" >> $demo_log
        echo "[$now] Launching session $next_session" >> $demo_log

        # Launch new session in new xterm
        echo "Launching new xterm for session $next_session..."
        xterm -title "Demo Session $next_session" -e "csh $demo_script $next_session $next_elapsed $demo_dir" &

        echo "New session launched, exiting current session"
        set session_relaunched = 1
        set target_done = 1
        break
    endif

    sleep $check_interval
    @ elapsed_time += $check_interval
    @ session_elapsed += $check_interval
end

echo ""

# Handle exit based on what happened
if ($session_relaunched == 1) then
    echo "Session handoff complete - this session is now exiting"
    echo ""
    echo "This xterm should close in 3 seconds..."
    sleep 3
    # Force shell termination
    exec /bin/true
else if ($target_success == 1) then
    echo "Demo completed successfully!"
    echo ""
    echo "Check log file: $demo_log"
    echo "----------------------------------------"
    cat $demo_log
    echo "----------------------------------------"
    echo ""
    echo "Press Enter to close..."
    set dummy = "$<"
else
    echo "Demo ended unexpectedly"
endif
