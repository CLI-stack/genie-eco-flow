#!/bin/tcsh -f
#
# TEST SCRIPT: Self-Chaining Monitor Demo
#
# This script demonstrates the self-relaunch mechanism for long-running monitoring.
# Uses SHORT timeouts for testing (2 minutes instead of 23 hours).
#
# Usage:
#   ./test_self_chain_monitor.csh <test_dir> <target_completion_time_seconds>
#
# Example:
#   ./test_self_chain_monitor.csh /tmp/test_monitor 300
#   (Target will "complete" after 300 seconds / 5 minutes)
#
# The script will:
#   1. Start monitoring (or resume from checkpoint)
#   2. Every 10 seconds, check if "target" is done
#   3. After 2 minutes (SESSION_TIMEOUT), relaunch itself in new xterm
#   4. Continue until target completes
#   5. Print "DONE - Email would be sent here" at the end
#

# =============================================================================
# CONFIGURATION - Adjust these for testing
# =============================================================================
set SESSION_TIMEOUT = 120        # 2 minutes (production would be 82800 = 23 hours)
set CHECK_INTERVAL = 10          # Check every 10 seconds
set STATUS_REPORT_INTERVAL = 30  # Report status every 30 seconds

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
if ($#argv < 1) then
    echo "Usage: $0 <test_dir> [target_completion_time_seconds]"
    echo ""
    echo "Example:"
    echo "  $0 /tmp/test_monitor 300"
    echo ""
    echo "This will simulate a target that completes after 300 seconds (5 minutes)"
    echo "The script will self-relaunch every 2 minutes to demonstrate chaining."
    exit 1
endif

set test_dir = "$1"
set target_completion_time = 300  # Default: 5 minutes

if ($#argv >= 2) then
    set target_completion_time = "$2"
endif

# =============================================================================
# SETUP
# =============================================================================
set script_path = "$0"
set script_dir = `dirname $script_path`
set checkpoint_file = "${test_dir}/monitor_checkpoint.txt"
set target_done_file = "${test_dir}/target_complete.flag"
set log_file = "${test_dir}/monitor.log"

# Create test directory if not exists
if (! -d $test_dir) then
    mkdir -p $test_dir
    echo "[`date`] Created test directory: $test_dir"
endif

# =============================================================================
# CHECKPOINT FUNCTIONS (using files since tcsh doesn't have functions)
# =============================================================================

# Check if we're resuming from checkpoint
set is_resume = 0
set total_elapsed = 0
set session_number = 1
set start_timestamp = `date +%s`

if (-f $checkpoint_file) then
    echo "[`date`] Found checkpoint file - RESUMING"
    set is_resume = 1

    # Read checkpoint values
    set total_elapsed = `grep "^total_elapsed=" $checkpoint_file | sed 's/total_elapsed=//'`
    set session_number = `grep "^session_number=" $checkpoint_file | sed 's/session_number=//'`
    set start_timestamp = `grep "^start_timestamp=" $checkpoint_file | sed 's/start_timestamp=//'`

    echo "[`date`] Resumed from checkpoint:"
    echo "  - Total elapsed: ${total_elapsed}s"
    echo "  - Session number: $session_number"
    echo "  - Original start: $start_timestamp"

    # Increment session number
    @ session_number += 1
else
    echo "[`date`] No checkpoint found - FRESH START"
    set start_timestamp = `date +%s`

    # Write initial values to log
    echo "========================================" >> $log_file
    echo "Monitor started at `date`" >> $log_file
    echo "Target completion time: ${target_completion_time}s" >> $log_file
    echo "Session timeout: ${SESSION_TIMEOUT}s" >> $log_file
    echo "========================================" >> $log_file
endif

echo ""
echo "=========================================="
echo "SELF-CHAINING MONITOR - SESSION $session_number"
echo "=========================================="
echo "Test directory: $test_dir"
echo "Target completes after: ${target_completion_time}s total"
echo "Session timeout: ${SESSION_TIMEOUT}s"
echo "Check interval: ${CHECK_INTERVAL}s"
echo "Total elapsed so far: ${total_elapsed}s"
echo "=========================================="
echo ""

# =============================================================================
# MONITORING LOOP
# =============================================================================
set session_elapsed = 0
set target_done = 0

while ($target_done == 0)

    # Calculate total elapsed time
    set current_time = `date +%s`
    @ total_elapsed_now = $total_elapsed + $session_elapsed

    # ---------------------------------------------
    # CHECK 1: Is target complete?
    # ---------------------------------------------
    # In real script, this checks for ${target_name}.log.gz
    # For demo, we simulate completion after target_completion_time

    if ($total_elapsed_now >= $target_completion_time) then
        # Create the "done" flag file
        touch $target_done_file
    endif

    if (-f $target_done_file) then
        echo ""
        echo "=========================================="
        echo "[`date`] TARGET COMPLETED!"
        echo "=========================================="
        echo "Total monitoring time: ${total_elapsed_now}s"
        echo "Sessions used: $session_number"
        echo "=========================================="

        # Log completion
        echo "" >> $log_file
        echo "[`date`] TARGET COMPLETED after ${total_elapsed_now}s in $session_number sessions" >> $log_file

        # Clean up checkpoint
        rm -f $checkpoint_file
        echo "[`date`] Checkpoint file removed"

        set target_done = 1
        break
    endif

    # ---------------------------------------------
    # CHECK 2: Session timeout - need to relaunch?
    # ---------------------------------------------
    if ($session_elapsed >= $SESSION_TIMEOUT) then
        echo ""
        echo "=========================================="
        echo "[`date`] SESSION TIMEOUT - RELAUNCHING"
        echo "=========================================="

        # Save checkpoint BEFORE launching new session
        echo "Saving checkpoint..."
        echo "total_elapsed=$total_elapsed_now" > $checkpoint_file
        echo "session_number=$session_number" >> $checkpoint_file
        echo "start_timestamp=$start_timestamp" >> $checkpoint_file
        echo "target_completion_time=$target_completion_time" >> $checkpoint_file

        echo "Checkpoint saved:"
        cat $checkpoint_file

        # Log the handoff
        echo "" >> $log_file
        echo "[`date`] Session $session_number ended at ${session_elapsed}s, total ${total_elapsed_now}s" >> $log_file
        echo "[`date`] Launching session $session_number + 1" >> $log_file

        # Launch new xterm with same script
        echo ""
        echo "Launching new xterm to continue monitoring..."
        echo "Command: xterm -T 'Monitor Session $session_number+1' -e '$script_path $test_dir $target_completion_time'"

        # Launch in new xterm
        xterm -T "Monitor Session `expr $session_number + 1`" -e "$script_path $test_dir $target_completion_time" &

        echo "New xterm launched (PID: $!)"
        echo "This session will now exit."
        echo "=========================================="

        # Exit this session - new one will continue
        exit 0
    endif

    # ---------------------------------------------
    # STATUS REPORT (every STATUS_REPORT_INTERVAL seconds)
    # ---------------------------------------------
    if ($session_elapsed % $STATUS_REPORT_INTERVAL == 0) then
        set remaining_session = `expr $SESSION_TIMEOUT - $session_elapsed`
        set remaining_target = `expr $target_completion_time - $total_elapsed_now`

        echo "[`date`] Session $session_number | Session: ${session_elapsed}s/${SESSION_TIMEOUT}s | Total: ${total_elapsed_now}s | Target in: ${remaining_target}s"
    endif

    # ---------------------------------------------
    # SAVE CHECKPOINT (every loop - for crash recovery)
    # ---------------------------------------------
    echo "total_elapsed=$total_elapsed_now" > $checkpoint_file
    echo "session_number=$session_number" >> $checkpoint_file
    echo "start_timestamp=$start_timestamp" >> $checkpoint_file
    echo "target_completion_time=$target_completion_time" >> $checkpoint_file

    # Sleep and increment
    sleep $CHECK_INTERVAL
    @ session_elapsed += $CHECK_INTERVAL

end

# =============================================================================
# COMPLETION - This is where the agent would send email
# =============================================================================
echo ""
echo "=========================================="
echo "MONITORING COMPLETE - FINAL ACTIONS"
echo "=========================================="
echo ""
echo "In the real script, this is where:"
echo "  1. Results are written to data/\${tag}_spec"
echo "  2. updateTask.csh is called"
echo "  3. signature_quote.csh formats the email"
echo "  4. sendMail.py sends the final email"
echo ""
echo "=========================================="
echo "TEST COMPLETED SUCCESSFULLY"
echo "=========================================="

# Show the log
echo ""
echo "Monitor log:"
echo "------------"
cat $log_file

# Clean up
echo ""
echo "Cleaning up test files..."
rm -f $target_done_file
rm -f $checkpoint_file
echo "Done."

exit 0
