#!/bin/tcsh
# Test script for timing pass notification email

echo "========================================================================"
echo "TIMING PASS NOTIFICATION EMAIL TEST"
echo "========================================================================"

# Set test parameters
set source_dir = "/proj/rtg_oss_feint1/FEINT_AI_AGENT/abinbaba/rosenhorn_agent_flow/main_agent"
set tag = "test_timing_$$"
set tile_name = "umcdat_Jan19145714"
set tile_dir = "/proj/rtg_oss_er_feint2/abinbaba/ROSENHORN_DSO_v2/main/pd/tiles/umcdat_Jan19145714"
set target_name = "FxSynthesize"
set pass_number = 2
set file_path = "${tile_dir}/rpts/FxSynthesize/report_timing.pass_2.rpt.sum.sort_slack.endpts.gz"

echo "Test Parameters:"
echo "  source_dir: $source_dir"
echo "  tag: $tag"
echo "  tile_name: $tile_name"
echo "  tile_dir: $tile_dir"
echo "  target_name: $target_name"
echo "  pass_number: $pass_number"
echo "  file_path: $file_path"
echo ""

# Check if notification script exists
set notify_script = "$source_dir/script/rtg_oss_feint/supra/send_timing_pass_notification.csh"
if (! -f $notify_script) then
    echo "ERROR: Notification script not found: $notify_script"
    exit 1
endif

echo "Found notification script: $notify_script"
echo ""

# Check if we're in the correct directory
cd $source_dir
if ($status != 0) then
    echo "ERROR: Cannot change to source directory: $source_dir"
    exit 1
endif

echo "Changed to source directory: $source_dir"
echo ""

# Call the notification script
echo "Calling notification script..."
echo "Command: $notify_script $source_dir $tag $tile_name $tile_dir $target_name $pass_number $file_path"
echo ""

$notify_script "$source_dir" "$tag" "$tile_name" "$tile_dir" "$target_name" "$pass_number" "$file_path"

set exit_status = $status
echo ""
echo "========================================================================"
if ($exit_status == 0) then
    echo "✓ Notification script completed successfully"
else
    echo "✗ Notification script failed with exit code: $exit_status"
endif
echo "========================================================================"

# Show generated files
echo ""
echo "Generated files:"
if (-f ${source_dir}/data/${tag}_timing_pass${pass_number}_notify.spec) then
    echo "  Spec file: ${source_dir}/data/${tag}_timing_pass${pass_number}_notify.spec"
    echo ""
    echo "  Content preview:"
    head -25 ${source_dir}/data/${tag}_timing_pass${pass_number}_notify.spec | sed 's/^/    /'
endif

if (-f ${source_dir}/data/${tag}_timing_pass${pass_number}_notify.html) then
    echo ""
    echo "  HTML file: ${source_dir}/data/${tag}_timing_pass${pass_number}_notify.html"
endif

echo ""
echo "========================================================================"
echo "Testing tile prefix detection logic"
echo "========================================================================"

# Test tile prefix extraction
foreach test_tile (umcdat_Jan19145714 umccmd_Jan20123456 other_tile_name)
    set tile_prefix = `echo $test_tile | sed 's/_.*//g'`
    echo "Tile: $test_tile → Prefix: $tile_prefix"
    if ("$tile_prefix" == "umccmd" || "$tile_prefix" == "umcdat") then
        echo "  ✓ Would check for timing reports"
    else
        echo "  ✗ Would skip (not umccmd/umcdat)"
    endif
end

exit $exit_status
