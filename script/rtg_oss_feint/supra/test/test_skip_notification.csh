#!/bin/tcsh
# Test script for skip notification email
# This will send a test email without running actual TileBuilder

echo "========================================================================"
echo "SKIP NOTIFICATION EMAIL TEST"
echo "========================================================================"

# Set test parameters
set source_dir = "/proj/rtg_oss_feint1/FEINT_AI_AGENT/abinbaba/rosenhorn_agent_flow/main_agent"
set tag = "test_skip_notify_$$"
set tile_name = "umcdat_Jan22190350"
set tile_dir = "/proj/rtg_oss_er_feint2/abinbaba/ROSENHORN_DSO_v2/main/pd/tiles/umcdat_Jan22190350"
set target_name = "FxSynthesize"

# Create test skipped tasks file
set test_skip_file = "/tmp/test_skip_tasks_$$.tmp"
echo "GetSdc" > $test_skip_file

echo "Test Parameters:"
echo "  source_dir: $source_dir"
echo "  tag: $tag"
echo "  tile_name: $tile_name"
echo "  tile_dir: $tile_dir"
echo "  target_name: $target_name"
echo "  skipped_tasks: GetSdc"
echo ""

# Check if notification script exists
set notify_script = "$source_dir/script/rtg_oss_feint/supra/send_skip_notification.csh"
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
echo "Command: $notify_script $source_dir $tag $tile_name $tile_dir $test_skip_file $target_name"
echo ""

$notify_script "$source_dir" "$tag" "$tile_name" "$tile_dir" "$test_skip_file" "$target_name"

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
if (-f ${source_dir}/data/${tag}_skip_notify.spec) then
    echo "  Spec file: ${source_dir}/data/${tag}_skip_notify.spec"
    echo ""
    echo "  Content preview:"
    head -20 ${source_dir}/data/${tag}_skip_notify.spec | sed 's/^/    /'
endif

if (-f ${source_dir}/data/${tag}_skip_notify.html) then
    echo ""
    echo "  HTML file: ${source_dir}/data/${tag}_skip_notify.html"
endif

exit $exit_status
