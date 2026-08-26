#!/bin/tcsh
# run_tilebuilder_noninteractive.csh - Run TileBuilder commands without GUI
# Usage: run_tilebuilder_noninteractive.csh <tile_directory>

set tile_dir = $1

if ("$tile_dir" == "") then
    echo "Usage: $0 <tile_directory>"
    echo "Example: $0 /path/to/tiles/umc_top_Jan15213045"
    exit 1
endif

# Find GUI directory
set tiles_parent = `dirname $tile_dir`
set gui_dir = `find $tiles_parent -maxdepth 1 -type d -name "*_GUI" | head -1`

if ("$gui_dir" == "") then
    echo "ERROR: No GUI directory found in $tiles_parent"
    exit 1
endif

echo "=========================================="
echo "TileBuilder Non-Interactive Execution"
echo "=========================================="
echo "Tile directory: $tile_dir"
echo "GUI directory:  $gui_dir"
echo ""

# Navigate to GUI directory
cd $gui_dir
echo "Changed to GUI directory: `pwd`"

# Source TileBuilder environment
if (-f .TBProjectEnv.csh) then
    echo "Sourcing TileBuilder environment..."
    source .TBProjectEnv.csh
    echo "✓ TileBuilder environment loaded"
else
    echo "ERROR: .TBProjectEnv.csh not found in GUI directory"
    echo "This might not be a valid TileBuilder GUI directory"
    exit 1
endif
echo ""

# Check if TileBuilder commands are available
echo "Checking TileBuilder commands..."
which TileBuilderShow >& /dev/null
if ($status == 0) then
    echo "✓ TileBuilderShow command available"
else
    echo "ERROR: TileBuilderShow command not found after sourcing environment"
    echo "TileBuilder environment may not be set up correctly"
    exit 1
endif
echo ""

# Run TileBuilderShow
set output_log = "${tile_dir}/status.log"
echo "Running TileBuilderShow..."
echo "Command: cd $tile_dir && TileBuilderShow"
echo "Output: $output_log"

cd $tile_dir
TileBuilderShow >& $output_log

if (-f $output_log && -s $output_log) then
    echo "✓ TileBuilderShow completed successfully"
    echo ""
    echo "Output (first 20 lines):"
    head -20 $output_log
    echo ""
    echo "Full output saved to: $output_log"
else
    echo "ERROR: TileBuilderShow failed or produced no output"
    exit 1
endif

echo ""
echo "=========================================="
echo "Completed successfully"
echo "=========================================="
