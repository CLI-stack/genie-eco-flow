#!/bin/tcsh
# Test script for status_check log cleanup logic

echo "========================================================================"
echo "TESTING STATUS_CHECK LOG CLEANUP"
echo "========================================================================"

# Create test directory
set test_dir = "/tmp/test_status_cleanup_$$"
mkdir -p $test_dir
echo "Created test directory: $test_dir"
echo ""

# Create some test status_check log files
echo "Creating test log files..."
touch ${test_dir}/status_check_0.log
touch ${test_dir}/status_check_300.log
touch ${test_dir}/status_check_600.log
touch ${test_dir}/status_check_900.log
touch ${test_dir}/status_check_1200.log

echo "Created 5 test log files:"
ls -lh ${test_dir}/status_check_*.log
echo ""

# Make some files older (simulate files from 35 minutes ago)
echo "Making some files older (simulating 35+ minutes ago)..."
touch -t `date -d '35 minutes ago' +%Y%m%d%H%M.%S` ${test_dir}/status_check_0.log 2>/dev/null || touch -d '35 minutes ago' ${test_dir}/status_check_0.log 2>/dev/null || echo "Note: Cannot modify file timestamps on this system"
touch -t `date -d '40 minutes ago' +%Y%m%d%H%M.%S` ${test_dir}/status_check_300.log 2>/dev/null || touch -d '40 minutes ago' ${test_dir}/status_check_300.log 2>/dev/null || echo "Note: Cannot modify file timestamps on this system"
echo ""

echo "Current files with timestamps:"
ls -lh ${test_dir}/status_check_*.log
echo ""

# Test 1: Check if find command works
echo "========================================================================"
echo "TEST 1: Testing find command with -mmin +30"
echo "========================================================================"
echo "Command: find ${test_dir} -name 'status_check_*.log' -mmin +30"
echo ""

# Use temp file to avoid stderr redirection issues in backticks
find ${test_dir} -name "status_check_*.log" -mmin +30 >& /tmp/test_old_logs_$$.tmp
if ($status == 0) then
    echo "✓ Find command executed successfully"
    echo ""
    if (-f /tmp/test_old_logs_$$.tmp && -s /tmp/test_old_logs_$$.tmp) then
        echo "Files found (older than 30 minutes):"
        foreach file (`cat /tmp/test_old_logs_$$.tmp`)
            echo "  - $file"
        end
    else
        echo "No files older than 30 minutes found (this is expected if touch -d didn't work)"
    endif
else
    echo "✗ Find command failed with status: $status"
endif
rm -f /tmp/test_old_logs_$$.tmp
echo ""

# Test 2: Test cleanup loop logic
echo "========================================================================"
echo "TEST 2: Testing cleanup loop logic"
echo "========================================================================"
set cleanup_count = 0
# Use temp file to avoid stderr redirection issues in backticks
find ${test_dir} -name "status_check_*.log" -mmin +30 >& /tmp/test_old_logs2_$$.tmp
if (-f /tmp/test_old_logs2_$$.tmp && -s /tmp/test_old_logs2_$$.tmp) then
    foreach old_log (`cat /tmp/test_old_logs2_$$.tmp`)
        if (-f "$old_log") then
            echo "Deleting: $old_log"
            rm -f "$old_log"
            if ($status == 0) then
                echo "  ✓ Successfully deleted"
                @ cleanup_count += 1
            else
                echo "  ✗ Failed to delete (status: $status)"
            endif
        endif
    end
endif
rm -f /tmp/test_old_logs2_$$.tmp

echo ""
if ($cleanup_count > 0) then
    echo "✓ Cleaned up $cleanup_count old status_check log files"
else
    echo "No files were cleaned up (this is OK if timestamps couldn't be modified)"
endif
echo ""

# Show remaining files
echo "Remaining files after cleanup:"
ls -lh ${test_dir}/status_check_*.log 2>/dev/null
if ($status != 0) then
    echo "  (No files remaining - all were cleaned up)"
endif
echo ""

# Test 3: Test with no old files
echo "========================================================================"
echo "TEST 3: Testing cleanup when no old files exist"
echo "========================================================================"
set cleanup_count = 0
find ${test_dir} -name "status_check_*.log" -mmin +30 >& /tmp/test_old_logs3_$$.tmp
if (-f /tmp/test_old_logs3_$$.tmp && -s /tmp/test_old_logs3_$$.tmp) then
    foreach old_log (`cat /tmp/test_old_logs3_$$.tmp`)
        if (-f "$old_log") then
            rm -f "$old_log"
            @ cleanup_count += 1
        endif
    end
endif
rm -f /tmp/test_old_logs3_$$.tmp

if ($cleanup_count > 0) then
    echo "Cleaned up $cleanup_count files"
else
    echo "✓ No files to clean up (cleanup_count = 0) - This is the expected behavior"
endif
echo ""

# Test 4: Test arithmetic operations
echo "========================================================================"
echo "TEST 4: Testing modulo operation for 30-minute intervals"
echo "========================================================================"
set target_elapsed = 0
echo "Testing target_elapsed values and cleanup trigger:"
foreach elapsed (0 300 600 900 1200 1500 1800 2100 2400 2700 3000 3300 3600)
    set target_elapsed = $elapsed
    @ remainder = $target_elapsed % 1800
    if ($target_elapsed % 1800 == 0 && $target_elapsed > 0) then
        echo "  $elapsed seconds (${elapsed}/60 = $elapsed:t minutes) → ✓ CLEANUP TRIGGERED"
    else
        echo "  $elapsed seconds → cleanup not triggered (remainder: $remainder)"
    endif
end
echo ""

# Cleanup test directory
echo "========================================================================"
echo "Cleaning up test directory..."
rm -rf $test_dir
if ($status == 0) then
    echo "✓ Test directory removed successfully"
else
    echo "✗ Failed to remove test directory: $test_dir"
endif

echo "========================================================================"
echo "TEST COMPLETED"
echo "========================================================================"
