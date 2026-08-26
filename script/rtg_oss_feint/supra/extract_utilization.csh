#!/bin/tcsh
# Extract utilization report for agent
# Called by agent task execution
# Parameters: refDir, tag

set refDir = $1
set tag = $2
set source_dir = `pwd`
touch $source_dir/data/${tag}_spec

set refdir_name = `echo $refDir | sed 's/:/ /g' | awk '{$1="";print $0}'`

# Validate refdir
if ("$refdir_name" == "" || "$refdir_name" == " ") then
    echo "ERROR: refdir is empty or invalid" >> $source_dir/data/${tag}_spec
    set run_status = "failed"
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
    exit 1
endif

# Check if directory exists
if (! -d $refdir_name) then
    echo "ERROR: Directory not found: $refdir_name" >> $source_dir/data/${tag}_spec
    set run_status = "failed"
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
    exit 1
endif

# Check if this is a TileBuilder directory (has revrc.main)
if (! -f "$refdir_name/revrc.main") then
    echo "ERROR: Not a TileBuilder directory (revrc.main not found)" >> $source_dir/data/${tag}_spec
    echo "Directory: $refdir_name" >> $source_dir/data/${tag}_spec
    set run_status = "failed"
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
    exit 1
endif

echo "TileBuilder directory validated: $refdir_name"

setenv TZ 'Asia/Kuala_Lumpur'
set date = `date +%d-%b`
unsetenv TZ

# Change to TileBuilder directory
cd $refdir_name

# Check if data/Synthesize.nlib exists (it's a directory)
if (! -e "data/Synthesize.nlib") then
    echo "#text#" >> $source_dir/data/${tag}_spec
    echo "ERROR: data/Synthesize.nlib not found in $refdir_name" >> $source_dir/data/${tag}_spec
    echo "#text end#" >> $source_dir/data/${tag}_spec
    cd $source_dir
    set run_status = "failed"
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
    exit 1
endif

echo "data/Synthesize.nlib found, proceeding..."

# Clean up tmpFilesForTileBuilderIntFX if it exists
if (-d "tmpFilesForTileBuilderIntFX") then
    echo "Removing existing tmpFilesForTileBuilderIntFX directory..."
    rm -rf tmpFilesForTileBuilderIntFX
endif

# Source LSF environment (TileBuilder-compatible, without cbwa_init.csh)
source $source_dir/script/rtg_oss_feint/lsf_tilebuilder.csh

# Set environment variable for TCL script to use
setenv AGENT_TAG $tag

# Generate utilization report using TileBuilderTerm
echo "Generating utilization report..."
TileBuilderTerm -x "TileBuilderIntFX data/Synthesize.nlib -a $source_dir/script/rtg_oss_feint/supra/report_utilization.tcl --nogui" &

# Wait for report generation (max 30 minutes, check every 1 minute)
set max_wait = 30
set wait_count = 0
set report_file = ""

echo "Waiting for report generation (max ${max_wait} minutes)..."

while ($wait_count < $max_wait)
    sleep 60
    set wait_count = `expr $wait_count + 1`

    # Check if report exists
    set report_file = `find . -name "agent_utilization_report_${tag}.rpt" -type f |& grep -v "Permission denied" | head -1`

    if ("$report_file" != "") then
        echo "Report found after ${wait_count} minute(s): $report_file"
        break
    endif

    echo "Waiting... (${wait_count}/${max_wait} minutes elapsed)"
end

# Check if report was found
if ("$report_file" == "") then
    echo "#text#" >> $source_dir/data/${tag}_spec
    echo "ERROR: Utilization report generation timed out after ${max_wait} minutes" >> $source_dir/data/${tag}_spec
    echo "Searched for: agent_utilization_report_${tag}.rpt in $refdir_name" >> $source_dir/data/${tag}_spec
    echo "#text end#" >> $source_dir/data/${tag}_spec
    cd $source_dir
    set run_status = "failed"
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
    exit 1
endif

echo "Report generation completed successfully"

# Wait 2 minutes to ensure report is fully written
echo "Waiting 2 minutes for report to be fully written..."
sleep 120

# Output report content
echo "#text#" >> $source_dir/data/${tag}_spec
echo "Utilization report location: $refdir_name/$report_file" >> $source_dir/data/${tag}_spec
echo "" >> $source_dir/data/${tag}_spec
cat $report_file >> $source_dir/data/${tag}_spec

cd $source_dir
set run_status = "finished"
source csh/env.csh
source csh/updateTask.csh
