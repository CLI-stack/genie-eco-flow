#!/bin/tcsh
# Enhanced Supra Regression Status Checker
# Usage: check_status_supra_regression.csh <refDir> <tile> <target> <tag>
# Checks TileBuilder status using TileBuilderShow command

set refDir = $1
set tile = $2
set target = $3
set tag = $4
set source_dir = `pwd`
touch $source_dir/data/${tag}_spec

# Parse parameters
set refdir_name = `echo $refDir | sed 's/:/ /g' | awk '{$1="";print $0}'`
set tile_name = `echo $tile | sed 's/:/ /g' | awk '{$1="";print $0}'`
set target_name = `echo $target | sed 's/:/ /g' | awk '{$1="";print $0}'`

# Validate refdir
if ("$refdir_name" == "" || "$refdir_name" == " ") then
    echo "ERROR: refdir is empty or invalid" >> $source_dir/data/${tag}_spec
    exit 1
endif

# Check if directory exists
if (! -d $refdir_name) then
    echo "ERROR: Directory not found: $refdir_name" >> $source_dir/data/${tag}_spec
    exit 1
endif

# Check if this is a TileBuilder directory (has revrc.main)
if (! -f "$refdir_name/revrc.main") then
    echo "ERROR: Not a TileBuilder directory (revrc.main not found)" >> $source_dir/data/${tag}_spec
    echo "Directory: $refdir_name" >> $source_dir/data/${tag}_spec
    exit 1
endif

echo "TileBuilder directory validated: $refdir_name"

# Navigate to TileBuilder directory
cd $refdir_name

# Generate timestamp for log file
setenv TZ 'Asia/Kuala_Lumpur'
set datetime = `date +%Y%m%d_%H%M%S`
unsetenv TZ

set status_log = "${refdir_name}/status_${datetime}.log"

echo "Running TileBuilderShow to get status..."
echo "Output log: $status_log"

# Run TileBuilderShow and filter out NOTRUN and BLOCKED
TileBuilderTerm -x "TileBuilderShow | grep -v NOTRUN | grep -v BLOCKED >& $status_log"

# Wait for log file to be created and have content
set max_wait = 30
set elapsed = 0
while ($elapsed < $max_wait)
    if (-f $status_log && -s $status_log) then
        echo "Status log created with content"
        break
    endif
    sleep 1
    @ elapsed++
end

# Check if log was created
if (! -f $status_log) then
    echo "ERROR: Failed to generate status log" >> $source_dir/data/${tag}_spec
    exit 1
endif

# Check if log has content
if (! -s $status_log) then
    echo "WARNING: Status log is empty (all tasks may be NOTRUN/BLOCKED)" >> $source_dir/data/${tag}_spec
endif

# Parse the log file and output CSV
echo "#text#" >> $source_dir/data/${tag}_spec
echo "Supra Regression Status" >> $source_dir/data/${tag}_spec
echo "========================================" >> $source_dir/data/${tag}_spec
echo "TileBuilder Directory: $refdir_name" >> $source_dir/data/${tag}_spec
echo "Status Log: $status_log" >> $source_dir/data/${tag}_spec
echo "" >> $source_dir/data/${tag}_spec
echo "#table#" >> $source_dir/data/${tag}_spec
echo "TaskID,Target,Status" >> $source_dir/data/${tag}_spec

# Parse log file - Format: TaskID TargetName STATUS
foreach line ("`cat $status_log`")
    # Skip empty lines
    if ("$line" == "") continue
    
    # Parse line: 1751 UpdateTunable PASSED
    set task_id = `echo "$line" | awk '{print $1}'`
    set task_name = `echo "$line" | awk '{print $2}'`
    set task_status = `echo "$line" | awk '{print $3}'`
    
    # Filter by target if specified
    if ("$target_name" != "" && "$target_name" != " ") then
        # Only show tasks matching the specified target
        if ("$task_name" == "$target_name") then
            echo "$task_id,$task_name,$task_status" >> $source_dir/data/${tag}_spec
        endif
    else
        # Show all tasks
        echo "$task_id,$task_name,$task_status" >> $source_dir/data/${tag}_spec
    endif
end

echo "#table end#" >> $source_dir/data/${tag}_spec
echo "" >> $source_dir/data/${tag}_spec

echo "Status check complete"

cd $source_dir
set run_status = "finished"
source csh/env.csh
source csh/updateTask.csh
