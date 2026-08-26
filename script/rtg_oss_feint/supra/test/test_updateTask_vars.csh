#!/bin/csh -f
# Test script to verify updateTask.csh variables are parsed correctly
# Usage: csh test_updateTask_vars.csh
# This simulates the monitor script flow with 1-minute timeout

set source_dir = `pwd`
set tag = "test_`date +%Y%m%d%H%M%S`"
set target_run_dir = ":"
set tile_name = "test_tile"
set refdir_name = "/tmp/test_refdir"
set target_name = "TestTarget"

echo "======================================================================"
echo "Test: updateTask.csh Variable Parsing"
echo "======================================================================"
echo "source_dir: $source_dir"
echo "tag: $tag"
echo "target_run_dir: $target_run_dir"
echo ""

# Create test data directory
mkdir -p $source_dir/data/${tag}
touch $source_dir/data/${tag}_spec

# Simulate completion - same flow as monitor_tilebuilder.csh lines 335-341
echo ""
echo "Simulating target completion..."
echo "Target $target_name completed successfully" >> $source_dir/data/${tag}_spec

cd $source_dir
set run_status = "finished"

if (! $?tasksModelFile) then
    set tasksModelFile = "tasksModel.csv"
endif

if (! $?n_instruction) then
    set n_instruction = 0
endif

echo ""
echo "Variables before sourcing updateTask.csh:"
echo "  tag: $tag"
echo "  run_status: $run_status"
echo "  target_run_dir: $target_run_dir"
echo "  tasksModelFile: $tasksModelFile"
echo "  n_instruction: $n_instruction"
echo "  source_dir: $source_dir"
echo ""

echo "======================================================================"
echo "Sourcing csh/env.csh..."
echo "======================================================================"
source csh/env.csh

echo ""
echo "======================================================================"
echo "Sourcing csh/updateTask.csh..."
echo "======================================================================"
source csh/updateTask.csh

echo ""
echo "======================================================================"
echo "Test completed successfully!"
echo "======================================================================"
echo "n_instruction after: $n_instruction"
echo ""

# Cleanup
echo "Cleaning up test files..."
rm -rf $source_dir/data/${tag}
rm -f $source_dir/data/${tag}_spec
rm -f $source_dir/data/${tag}_spec.html

echo "Done."
