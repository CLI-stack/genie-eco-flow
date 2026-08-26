#!/bin/tcsh
# Simple demo: How to invoke TileBuilderTerm
# Usage: test_tilebuilderterm.csh <tile_directory>

# Hardcoded path to lsf.csh for TileBuilderTerm environment setup
set lsf_script = "/proj/rtg_oss_feint1/FEINT_AI_AGENT/abinbaba/rosenhorn_agent_flow/main_agent/script/rtg_oss_feint/lsf.csh"

# Source LSF and TileBuilderTerm environment setup
if (-f $lsf_script) then
    echo "Sourcing environment from: $lsf_script"
    source $lsf_script
    echo "✓ Environment loaded"
    echo ""
else
    echo "ERROR: Cannot find lsf.csh at: $lsf_script"
    echo "Please check the script location"
    exit 1
endif

# Debug: Print environment variables
echo "=========================================="
echo "DEBUG: Environment Variables"
echo "=========================================="
if ($?TILEBUILDER_TERM) then
    echo "TILEBUILDER_TERM  = $TILEBUILDER_TERM (WARNING: Should be unset!)"
else
    echo "TILEBUILDER_TERM  = (not set - CORRECT, will use default xterm)"
endif
if ($?DISPLAY) then
    echo "DISPLAY           = $DISPLAY"
else
    echo "DISPLAY           = (not set)"
endif
if ($?XAUTHORITY) then
    echo "XAUTHORITY        = $XAUTHORITY"
else
    echo "XAUTHORITY        = (not set)"
endif
if ($?USER) then
    echo "USER              = $USER"
else
    echo "USER              = (not set)"
endif
if ($?HOME) then
    echo "HOME              = $HOME"
else
    echo "HOME              = (not set)"
endif
if ($?SHELL) then
    echo "SHELL             = $SHELL"
else
    echo "SHELL             = (not set)"
endif
if ($?SNPSLMD_LICENSE_FILE) then
    echo "SNPSLMD_LICENSE_FILE = $SNPSLMD_LICENSE_FILE" | cut -c1-120
else
    echo "SNPSLMD_LICENSE_FILE = (not set)"
endif
if ($?LM_LICENSE_FILE) then
    echo "LM_LICENSE_FILE      = $LM_LICENSE_FILE"
else
    echo "LM_LICENSE_FILE      = (not set)"
endif
if ($?SYNOPSYS) then
    echo "SYNOPSYS          = $SYNOPSYS"
else
    echo "SYNOPSYS          = (not set)"
endif
if ($?SYNOPSYS_PATH) then
    echo "SYNOPSYS_PATH     = $SYNOPSYS_PATH"
else
    echo "SYNOPSYS_PATH     = (not set)"
endif
if ($?PATH) then
    echo "PATH = $PATH" | cut -c1-120
else
    echo "PATH = (not set)"
endif
if ($?LD_LIBRARY_PATH) then
    echo "LD_LIBRARY_PATH = $LD_LIBRARY_PATH" | cut -c1-120
else
    echo "LD_LIBRARY_PATH = (not set)"
endif
if ($?TMPDIR) then
    echo "TMPDIR            = $TMPDIR"
else
    echo "TMPDIR            = (not set)"
endif
echo "=========================================="
echo ""

set tile_dir = $1
set original_dir = `pwd`

if ("$tile_dir" == "") then
    echo "Usage: $0 <tile_directory>"
    echo "Example: $0 /path/to/tiles/umc_top_Jan15213045"
    exit 1
endif

# Find GUI directory
set tiles_parent = `dirname $tile_dir`
set gui_dir = `find $tiles_parent -maxdepth 1 -type d -name "*_GUI" | head -1`

if ("$gui_dir" == "") then
    echo "ERROR: No GUI directory found"
    exit 1
endif

echo "Tile directory: $tile_dir"
echo "GUI directory: $gui_dir"
echo ""

# Navigate to GUI directory
cd $gui_dir

# Test if TileBuilderTerm is available
echo "Testing TileBuilderTerm availability..."
which TileBuilderTerm
if ($status != 0) then
    echo "ERROR: TileBuilderTerm command not found"
    echo "TileBuilder environment may not be loaded"
    exit 1
endif
echo "✓ TileBuilderTerm found"
echo ""

# Test invocation
echo "Testing TileBuilderTerm invocation..."
set test_log = "${tile_dir}/test_invoke.log"
set test_err = "${tile_dir}/test_invoke.err"
echo "Running: TileBuilderTerm -x with test command"
TileBuilderTerm -x "echo TileBuilderTerm test successful >& $test_log; echo Test completed - closing in 5 seconds; sleep 5" >& $test_err
sleep 2

if (-f $test_err && -s $test_err) then
    echo "TileBuilderTerm warnings/errors:"
    cat $test_err
    echo ""
endif

if (-f $test_log && -s $test_log) then
    echo "✓ TileBuilderTerm invocation successful (warnings can be ignored)"
    cat $test_log
    rm -f $test_log $test_err
else
    echo "ERROR: TileBuilderTerm invocation failed"
    echo "Check error log: $test_err"
    exit 1
endif
echo ""

# Invoke TileBuilderTerm to run TileBuilderShow
set output_log = "${tile_dir}/status.log"
set show_err = "${tile_dir}/tilebuildershow.err"
echo "Running TileBuilderShow..."
echo "Running: TileBuilderTerm -x with TileBuilderShow command"
TileBuilderTerm -x "cd $tile_dir; TileBuilderShow >& $output_log; echo TileBuilderShow completed - closing in 10 seconds; sleep 10" >& $show_err
sleep 5

if (-f $show_err && -s $show_err) then
    echo "TileBuilderTerm warnings/errors:"
    cat $show_err
    echo ""
endif

if (-f $output_log && -s $output_log) then
    echo "✓ Status log created successfully: $output_log"
    echo ""
    echo "Sample output (first 5 lines):"
    head -5 $output_log
    rm -f $show_err
else
    echo "ERROR: Status log not created or empty"
    echo "Check error log: $show_err"
    cd $original_dir
    exit 1
endif

# Return to original directory
cd $original_dir
echo ""
echo "Returned to original directory: $original_dir"
