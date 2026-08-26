#!/bin/tcsh
# Test script for waiver and blocking pattern validation
# Usage: test_waiver_blocking_check.csh <tile_directory>

set tile_dir = $1
set source_dir = /proj/rtg_oss_feint1/FEINT_AI_AGENT/abinbaba/rosenhorn_agent_flow/main_agent

if ("$tile_dir" == "") then
    echo "Usage: $0 <tile_directory>"
    echo "Example: $0 /proj/rtg_oss_er_feint2/abinbaba/ROSENHORN_DSO_v2/main/pd/tiles/umcdat_Jan22144419"
    exit 1
endif

if (! -d $tile_dir) then
    echo "ERROR: Tile directory not found: $tile_dir"
    exit 1
endif

set final_tile_dir = "$tile_dir"
set final_tile_name = `basename $final_tile_dir`

echo "======================================================================"
echo "WAIVER AND BLOCKING PATTERN VALIDATION TEST"
echo "======================================================================"
echo "Tile directory: $final_tile_dir"
echo "Tile name: $final_tile_name"
echo ""

# Simulate getting failed tasks from TileBuilderShow
echo "Creating simulated failed tasks file..."
echo "3118 GetSdc FAILED" > ${final_tile_dir}/failed_tasks.tmp

if (! -f ${final_tile_dir}/failed_tasks.tmp || ! -s ${final_tile_dir}/failed_tasks.tmp) then
    echo "ERROR: Failed to create test failed_tasks.tmp"
    exit 1
endif

echo "DEBUG: Failed tasks content:"
cat ${final_tile_dir}/failed_tasks.tmp
echo ""

# Check waiver file
set waiver_file = "${source_dir}/script/rtg_oss_feint/supra/supra_task_skip.txt"

echo "DEBUG: Waiver file path: $waiver_file"
if (-f $waiver_file) then
    echo "DEBUG: Waiver file exists: YES"
    echo "DEBUG: Waiver file content:"
    cat $waiver_file
    echo ""
else
    echo "ERROR: Waiver file not found"
    exit 1
endif

echo "DEBUG: Creating clean waiver list"
grep -v '^#' $waiver_file | grep -v '^[ ]*$' > ${final_tile_dir}/waiver_clean.tmp
if (! -s ${final_tile_dir}/waiver_clean.tmp) then
    echo "DEBUG: No waiver entries found (file empty after filtering)"
    touch ${final_tile_dir}/waiver_clean.tmp
endif

echo "DEBUG: Clean waiver list content:"
cat ${final_tile_dir}/waiver_clean.tmp
echo ""

# Extract task names from failed tasks
echo "DEBUG: Extracting task names from failed tasks"
awk '{print $2}' ${final_tile_dir}/failed_tasks.tmp > ${final_tile_dir}/failed_task_names.tmp

echo "DEBUG: Failed task names:"
cat ${final_tile_dir}/failed_task_names.tmp
echo ""

# Check if all failed tasks are in waiver list and extract root cause patterns
echo "DEBUG: Checking each failed task against waiver list"
set all_waived = 1

# Create a file to store task -> pattern mapping
set WAIVER_PATTERNS = "${final_tile_dir}/waiver_patterns.tmp"
rm -f $WAIVER_PATTERNS

foreach task_name (`cat ${final_tile_dir}/failed_task_names.tmp`)
    echo "DEBUG: Checking task: $task_name"
    # Check if task exists in waiver file
    grep "^${task_name}:" ${final_tile_dir}/waiver_clean.tmp > /tmp/waiver_line_$$.tmp
    if ($status != 0) then
        echo "Task $task_name is NOT waived"
        set all_waived = 0
        break
    else
        echo "Task $task_name is waived"
        # Extract the root cause pattern (everything after the colon) to a file
        sed 's/^[^:]*: *//' /tmp/waiver_line_$$.tmp > /tmp/pattern_$$.tmp
        echo -n "  Expected root cause pattern: "
        cat /tmp/pattern_$$.tmp
        # Store task name and pattern for later use - read pattern from file to avoid glob expansion
        echo -n "${task_name}:::" >> $WAIVER_PATTERNS
        cat /tmp/pattern_$$.tmp >> $WAIVER_PATTERNS
        rm -f /tmp/waiver_line_$$.tmp /tmp/pattern_$$.tmp
    endif
end

echo ""
echo "DEBUG: all_waived = $all_waived"

if ($all_waived == 1) then
    # Check for universal blocking patterns before allowing skip
    echo ""
    echo "======================================================================"
    echo "All failed tasks are in waiver file - checking for blocking patterns..."
    echo "======================================================================"

    set blocking_check_passed = 1

    foreach task_name (`cat ${final_tile_dir}/failed_task_names.tmp`)
        echo ""
        echo "Checking blocking patterns for task: $task_name"

        # Get the expected root cause pattern for this task (store in file to avoid glob expansion)
        set EXPECTED_PATTERN_FILE = "/tmp/expected_pattern_$$.tmp"
        grep "^${task_name}:::" $WAIVER_PATTERNS | sed 's/^[^:]*::://' > $EXPECTED_PATTERN_FILE
        echo -n "  Expected root cause pattern: "
        cat $EXPECTED_PATTERN_FILE

        set task_log = "${final_tile_dir}/logs/${task_name}.log.gz"

        if (! -f $task_log) then
            echo "  WARNING: Log file not found: $task_log"
            echo "  Cannot verify blocking patterns - denying skip for safety"
            set blocking_check_passed = 0
            break
        endif

        echo "  Log file: $task_log"

        # Check for universal blocking patterns that prevent skipping
        echo "  Checking for universal blocking patterns..."
        # Use separate grep commands to avoid regex issues and track which patterns match
        set TMPFILE = "/tmp/blocking_check_$$.tmp"
        set PATTERNS_MATCHED = "/tmp/blocking_patterns_matched_$$.tmp"
        rm -f $TMPFILE $PATTERNS_MATCHED

        # Check each pattern and log which ones match
        zcat "$task_log" | grep -E "ERROR: Output dependency file.*was not created" > /tmp/check1_$$.tmp
        if (-s /tmp/check1_$$.tmp) then
            cat /tmp/check1_$$.tmp >> $TMPFILE
            echo "Missing output dependency files" >> $PATTERNS_MATCHED
        endif

        zcat "$task_log" | grep -E "license error|License checkout failed" > /tmp/check2_$$.tmp
        if (-s /tmp/check2_$$.tmp) then
            cat /tmp/check2_$$.tmp >> $TMPFILE
            echo "License checkout failure" >> $PATTERNS_MATCHED
        endif

        zcat "$task_log" | grep -E "segmentation fault|Segmentation fault|core dumped" > /tmp/check3_$$.tmp
        if (-s /tmp/check3_$$.tmp) then
            cat /tmp/check3_$$.tmp >> $TMPFILE
            echo "Segmentation fault / core dump" >> $PATTERNS_MATCHED
        endif

        zcat "$task_log" | grep -E "killed by signal|Fatal Error|FATAL:|Abort|ABORT" > /tmp/check4_$$.tmp
        if (-s /tmp/check4_$$.tmp) then
            cat /tmp/check4_$$.tmp >> $TMPFILE
            echo "Fatal error / process killed" >> $PATTERNS_MATCHED
        endif

        rm -f /tmp/check1_$$.tmp /tmp/check2_$$.tmp /tmp/check3_$$.tmp /tmp/check4_$$.tmp

        if (-s $TMPFILE) then
            echo "  ✗ BLOCKING PATTERN FOUND - Cannot skip this failure!"
            echo "  Matched blocking patterns:"
            cat $PATTERNS_MATCHED | sed 's/^/    - /'
            echo ""
            echo "  Example errors from log:"
            head -3 $TMPFILE | sed 's/^/    /'

            # Extract root cause errors (all errors EXCEPT blocking patterns)
            echo "  Extracting root cause errors from log..."
            set ALLERRS = "/tmp/all_errors_$$.tmp"
            set ROOTCAUSE = "/tmp/root_cause_errors_$$.tmp"

            zcat "$task_log" | grep -E "^ERROR:|ERROR:" >& $ALLERRS

            # Filter out blocking pattern errors to get root cause
            grep -v -E 'ERROR: Output dependency file.*was not created|ERROR: Hit an error while trying to execute|ERROR: got an exit code not null|ERROR:[ ]*$' $ALLERRS >& $ROOTCAUSE

            if (-s $ROOTCAUSE) then
                echo "  Root cause errors found:"
                head -5 $ROOTCAUSE | sed 's/^/    /'

                # Clean and deduplicate root cause errors
                set ROOTCAUSE_CLEAN = "/tmp/root_cause_clean_$$.tmp"
                set ROOTCAUSE_UNIQUE = "/tmp/root_cause_unique_$$.tmp"

                # First clean all errors (remove prefixes and extra spaces)
                sed 's/^echo ERROR: //' $ROOTCAUSE | sed 's/^ERROR: //' | sed 's/  */ /g' > $ROOTCAUSE_CLEAN

                # Then deduplicate
                sort -u $ROOTCAUSE_CLEAN > $ROOTCAUSE_UNIQUE

                # Check if ALL root causes match the expected pattern (strict matching)
                echo ""
                echo "  Checking if ALL root causes match expected pattern..."
                set expected_pattern_text = `cat $EXPECTED_PATTERN_FILE`

                # Count total root causes
                set total_root_causes = `wc -l < $ROOTCAUSE_UNIQUE`

                # Count how many match the pattern
                grep -E "$expected_pattern_text" $ROOTCAUSE_UNIQUE > /tmp/matched_root_causes_$$.tmp
                set matched_count = `wc -l < /tmp/matched_root_causes_$$.tmp`

                echo "  Total root causes: $total_root_causes"
                echo "  Matched pattern: $matched_count"

                if ($total_root_causes == $matched_count && $matched_count > 0) then
                    echo "  ✓ ALL ROOT CAUSES MATCH EXPECTED PATTERN - Safe to skip!"
                    echo -n "  Pattern: "
                    cat $EXPECTED_PATTERN_FILE
                    # This task can be skipped - continue to next task
                    rm -f $TMPFILE $ALLERRS $ROOTCAUSE $ROOTCAUSE_CLEAN $ROOTCAUSE_UNIQUE $PATTERNS_MATCHED $EXPECTED_PATTERN_FILE /tmp/matched_root_causes_$$.tmp
                    continue
                else
                    echo "  ✗ NOT ALL ROOT CAUSES MATCH EXPECTED PATTERN - Cannot skip!"
                    echo -n "  Expected pattern: "
                    cat $EXPECTED_PATTERN_FILE
                    echo "  This is an unexpected failure"
                    echo ""
                    echo "  Root causes that DID NOT match:"
                    grep -v -E "$expected_pattern_text" $ROOTCAUSE_UNIQUE | sed 's/^/    /'
                    rm -f /tmp/matched_root_causes_$$.tmp
                endif

                echo ""
                echo "  Spec File Output Preview:"
                echo "  ========================================================"
                echo ""
                echo "  Task $task_name cannot be skipped due to:"
                echo -n "    Expected pattern: "
                cat $EXPECTED_PATTERN_FILE
                echo "    Actual root cause does NOT match expected pattern"
                echo ""

                foreach pattern_match ("`cat $PATTERNS_MATCHED`")
                    echo "    - $pattern_match"
                end

                echo ""
                echo "  Root cause errors:"
                echo "  #table#"
                echo "  Error_Type,Error_Message"

                set line_num = 0
                foreach error_line ("`cat $ROOTCAUSE_UNIQUE`")
                    @ line_num += 1
                    if ($line_num > 10) break
                    # Add quotes around the error message
                    echo "  Root Cause,'$error_line'"
                end

                echo "  #table end#"
                rm -f $ROOTCAUSE_CLEAN $ROOTCAUSE_UNIQUE
                echo ""
            else
                echo "  WARNING: No root cause errors extracted - only blocking patterns found"
                echo "  ✗ Cannot verify expected pattern match - Cannot skip!"
                echo -n "  Expected pattern: "
                cat $EXPECTED_PATTERN_FILE
                echo ""
                echo "  Spec File Output Preview:"
                echo "  ========================================================"
                echo ""
                echo "  Task $task_name cannot be skipped due to:"
                echo -n "    Expected pattern: "
                cat $EXPECTED_PATTERN_FILE
                echo "    No root cause found to verify pattern match"
                echo ""

                foreach pattern_match ("`cat $PATTERNS_MATCHED`")
                    echo "    - $pattern_match"
                end

                # Clean and deduplicate blocking pattern errors
                set TMPFILE_CLEAN = "/tmp/blocking_clean_$$.tmp"
                set TMPFILE_UNIQUE = "/tmp/blocking_unique_$$.tmp"

                # First clean all errors (remove ERROR: prefix and extra spaces)
                sed 's/^ERROR: //' $TMPFILE | sed 's/  */ /g' > $TMPFILE_CLEAN

                # Then deduplicate
                sort -u $TMPFILE_CLEAN > $TMPFILE_UNIQUE

                echo ""
                echo "  Blocking pattern errors:"
                echo "  #table#"
                echo "  Error_Type,Error_Message"

                set line_num = 0
                foreach error_line ("`cat $TMPFILE_UNIQUE`")
                    @ line_num += 1
                    if ($line_num > 10) break
                    # Add quotes around the error message
                    echo "  Blocking Pattern,'$error_line'"
                end

                echo "  #table end#"
                rm -f $TMPFILE_CLEAN $TMPFILE_UNIQUE
                echo ""
            endif

            set blocking_check_passed = 0
            echo ""
            echo "  Temp files created:"
            echo "    $TMPFILE"
            echo "    $ALLERRS"
            echo "    $ROOTCAUSE"
            echo "    $PATTERNS_MATCHED"
            break
        else
            echo "  ✓ No universal blocking patterns found"
            rm -f $TMPFILE $PATTERNS_MATCHED
        endif
    end

    echo ""
    echo "======================================================================"
    if ($blocking_check_passed == 1) then
        echo "✓ Blocking pattern check PASSED - Safe to skip waived tasks"
        set can_skip = 1
        echo "DEBUG: can_skip = 1"
    else
        echo "✗ Blocking pattern check FAILED - Cannot skip (fundamental failure detected)"
        set can_skip = 0
        echo "DEBUG: can_skip = 0"
    endif
    echo "======================================================================"
else
    echo "DEBUG: can_skip = 0 (not all tasks waived)"
    set can_skip = 0
endif

echo ""
echo "======================================================================"
echo "TEST COMPLETE"
echo "======================================================================"
echo "Final result: can_skip = $can_skip"
if ($can_skip == 1) then
    echo "✓ Tasks would be skipped and target re-run"
else
    echo "✗ Tasks would NOT be skipped - failure would be reported"
endif

# Cleanup
rm -f ${final_tile_dir}/failed_tasks.tmp ${final_tile_dir}/failed_task_names.tmp ${final_tile_dir}/waiver_clean.tmp

echo ""
echo "Test files preserved for inspection:"
if (-f ${final_tile_dir}/blocking_check_GetSdc.tmp) then
    echo "  ${final_tile_dir}/blocking_check_GetSdc.tmp"
endif
if (-f ${final_tile_dir}/all_errors_GetSdc.tmp) then
    echo "  ${final_tile_dir}/all_errors_GetSdc.tmp"
endif
if (-f ${final_tile_dir}/root_cause_errors_GetSdc.tmp) then
    echo "  ${final_tile_dir}/root_cause_errors_GetSdc.tmp"
endif
