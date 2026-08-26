#!/bin/csh -f
#
# Test script for Fast Mode Detection in make_tilebuilder_run.csh
# Tests the logic without actually running any TileBuilder commands
#
# Usage: source test_fast_mode_detection.csh <tile_dir> [target_name] [has_new_params]
#
# has_new_params: 0 = no new params (default), 1 = new params provided
#

if ($#argv < 1) then
    echo "Usage: source test_fast_mode_detection.csh <tile_dir> [target_name] [has_new_params]"
    echo "Example: source test_fast_mode_detection.csh /proj/.../tiles/umccmd_Jan19145714 FxSynthesize 0"
    echo ""
    echo "has_new_params: 0 = no new params (default), 1 = new params provided in instruction"
    exit 1
endif

set tile_dir = $1
set target_name = "FxSynthesize"
set has_new_params = 0

if ($#argv >= 2) then
    set target_name = $2
endif

if ($#argv >= 3) then
    set has_new_params = $3
endif

echo ""
echo "======================================================================"
echo "Fast Mode Detection Test"
echo "======================================================================"
echo "Tile directory: $tile_dir"
echo "Target: $target_name"
echo "New params provided: $has_new_params"
echo "======================================================================"
echo ""

# Step 0: Check for new params
echo "Step 0: Checking for new params in instruction..."
if ($has_new_params == 1) then
    echo "  [INFO] New params/controls detected in instruction"
    echo "  [INFO] This will force NORMAL MODE even if directory is ready"
else
    echo "  [INFO] No new params detected - Fast Mode eligible"
endif

# Step 1: Check if tile directory exists
echo "Step 1: Checking if tile directory exists..."
if (-d $tile_dir) then
    echo "  [PASS] Directory exists: $tile_dir"
else
    echo "  [FAIL] Directory does NOT exist: $tile_dir"
    echo ""
    echo "Result: NORMAL MODE (directory needs to be created)"
    exit 0
endif

# Step 2: Check if logs directory exists
echo ""
echo "Step 2: Checking if logs directory exists..."
set logs_dir = "${tile_dir}/logs"
if (-d $logs_dir) then
    echo "  [PASS] Logs directory exists: $logs_dir"
else
    echo "  [FAIL] Logs directory does NOT exist: $logs_dir"
    echo ""
    echo "Result: NORMAL MODE (no logs found)"
    exit 0
endif

# Step 3: Check if TileBuilderMake.log.gz exists
echo ""
echo "Step 3: Checking if TileBuilderMake.log.gz exists..."
set tilebuilder_make_log = "${tile_dir}/logs/TileBuilderMake.log.gz"
if (-f $tilebuilder_make_log) then
    echo "  [PASS] TileBuilderMake.log.gz exists: $tilebuilder_make_log"
    set log_size = `ls -lh $tilebuilder_make_log | awk '{print $5}'`
    echo "  Log size: $log_size"
else
    echo "  [FAIL] TileBuilderMake.log.gz does NOT exist: $tilebuilder_make_log"
    echo ""
    echo "Result: NORMAL MODE (TileBuilderMake not completed)"
    exit 0
endif

# Step 4: Check if TileBuilderMake:INFO: Done is in the log
echo ""
echo "Step 4: Checking for 'TileBuilderMake:INFO: Done' in log..."
set make_done = `zcat $tilebuilder_make_log | grep -c "TileBuilderMake:INFO: Done" || echo 0`
echo "  Match count: $make_done"

if ($make_done > 0) then
    echo "  [PASS] 'TileBuilderMake:INFO: Done' found in log"
    # Show the actual line
    echo ""
    echo "  Matching line(s):"
    zcat $tilebuilder_make_log | grep "TileBuilderMake:INFO: Done" | head -3 | sed 's/^/    /'
else
    echo "  [FAIL] 'TileBuilderMake:INFO: Done' NOT found in log"
    echo ""
    echo "  Last 10 lines of TileBuilderMake.log.gz:"
    zcat $tilebuilder_make_log | tail -10 | sed 's/^/    /'
    echo ""
    echo "Result: NORMAL MODE (TileBuilderMake did not complete successfully)"
    exit 0
endif

# Step 5: Check for UpdateTunable.log.gz (Phase 1 skip check)
echo ""
echo "Step 5: Checking for UpdateTunable.log.gz (Phase 1)..."
set update_tunable_log = "${tile_dir}/logs/UpdateTunable.log.gz"
if (-f $update_tunable_log) then
    echo "  [PASS] UpdateTunable.log.gz exists"
    set log_size = `ls -lh $update_tunable_log | awk '{print $5}'`
    echo "  Log size: $log_size"
else
    echo "  [INFO] UpdateTunable.log.gz does NOT exist (Phase 1 would wait for this)"
endif

# Step 6: Check for tune directory (Phase 2 skip check)
echo ""
echo "Step 6: Checking for tune directory (Phase 2)..."
set tune_dir = "${tile_dir}/tune"
if (-d $tune_dir) then
    echo "  [PASS] Tune directory exists: $tune_dir"
    set tune_target_dir = "${tune_dir}/${target_name}"
    if (-d $tune_target_dir) then
        echo "  [PASS] Tune target directory exists: $tune_target_dir"
        set tune_file_count = `ls -1 $tune_target_dir 2>/dev/null | wc -l`
        echo "  Tune files count: $tune_file_count"
    else
        echo "  [INFO] Tune target directory does NOT exist: $tune_target_dir"
    endif
else
    echo "  [INFO] Tune directory does NOT exist (Phase 2 would copy tune files)"
endif

# Step 7: Check for override.params and override.controls
echo ""
echo "Step 7: Checking for override files..."
if (-f "${tile_dir}/override.params") then
    echo "  [PASS] override.params exists"
    set params_lines = `wc -l < "${tile_dir}/override.params"`
    echo "  Lines: $params_lines"
else
    echo "  [INFO] override.params does NOT exist"
endif

if (-f "${tile_dir}/override.controls") then
    echo "  [PASS] override.controls exists"
    set controls_lines = `wc -l < "${tile_dir}/override.controls"`
    echo "  Lines: $controls_lines"
else
    echo "  [INFO] override.controls does NOT exist"
endif

# Step 8: Check current target status
echo ""
echo "Step 8: Checking current target status..."
set tiles_dir = `dirname $tile_dir`
set gui_dir = `find $tiles_dir -maxdepth 1 -type d -name "*_GUI" | head -1`

if ("$gui_dir" != "") then
    echo "  GUI directory: $gui_dir"
    if (-f "${gui_dir}/revrc.main") then
        echo "  [PASS] revrc.main exists"
    else
        echo "  [FAIL] revrc.main does NOT exist"
    endif
else
    echo "  [FAIL] No GUI directory found in $tiles_dir"
endif

# Final Result
echo ""
echo "======================================================================"
echo "FINAL RESULT"
echo "======================================================================"

# Determine final mode based on make_done AND has_new_params
set final_mode = "NORMAL"
if ($make_done > 0 && $has_new_params == 0) then
    set final_mode = "FAST"
endif

if ("$final_mode" == "FAST") then
    echo ""
    echo "  >>> FAST MODE ENABLED <<<"
    echo ""
    echo "  This directory is READY and NO new params provided."
    echo "  The script will:"
    echo "    - SKIP params centre copy"
    echo "    - SKIP tag params/controls merge"
    echo "    - SKIP TileBuilderGenParams"
    echo "    - SKIP TileBuilderMake"
    echo "    - SKIP Phase 1 (UpdateTunable wait)"
    echo "    - SKIP Phase 2 (tune centre copy)"
    echo "    - RUN serascmd --action run for target: $target_name"
    echo ""
    echo "  Command that would be executed:"
    set final_tile_name = `basename $tile_dir`
    echo "    cd $tile_dir; serascmd -find_jobs 'name=~$target_name dir=~$final_tile_name' --action run"
else
    echo ""
    echo "  >>> NORMAL MODE <<<"
    echo ""
    if ($make_done > 0 && $has_new_params == 1) then
        echo "  Directory is READY but NEW PARAMS were provided."
        echo "  Must update params and re-run TileBuilderGenParams/Make."
    else if ($make_done == 0) then
        echo "  Directory is NOT ready (TileBuilderMake not completed)."
    else
        echo "  Directory does not exist or missing logs."
    endif
    echo ""
    echo "  The script will run FULL setup:"
    echo "    - Copy params from params_centre"
    echo "    - Merge tag params/controls"
    echo "    - Run TileBuilderGenParams"
    echo "    - Run TileBuilderMake"
    echo "    - Wait Phase 1 (UpdateTunable)"
    echo "    - Copy tune files Phase 2"
    echo "    - Run serascmd --action run for target: $target_name"
endif
echo ""
echo "======================================================================"
