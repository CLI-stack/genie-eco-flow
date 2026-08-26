#!/bin/tcsh
# Simple test for timing pass notification - just send one email

echo "========================================================================"
echo "SIMPLE TIMING PASS NOTIFICATION TEST"
echo "========================================================================"

set source_dir = "/proj/rtg_oss_feint1/FEINT_AI_AGENT/abinbaba/rosenhorn_agent_flow/main_agent"
set tag = "test_timing_simple_$$"
set tile_name = "umcdat_Jan19145714"
set tile_dir = "/proj/rtg_oss_er_feint2/abinbaba/ROSENHORN_DSO_v2/main/pd/tiles/umcdat_Jan19145714"
set target_name = "FxSynthesize"
set pass_number = 2
set file_path = "${tile_dir}/rpts/FxSynthesize/report_timing.pass_2.rpt.sum.sort_slack.endpts.gz"

echo ""
echo "Sending timing pass notification for Pass ${pass_number}..."
echo ""

cd $source_dir

set notify_script = "$source_dir/script/rtg_oss_feint/supra/send_timing_pass_notification.csh"
$notify_script "$source_dir" "$tag" "$tile_name" "$tile_dir" "$target_name" "$pass_number" "$file_path"

if ($status == 0) then
    echo ""
    echo "========================================================================"
    echo "[OK] Email notification sent successfully!"
    echo "========================================================================"
    echo ""
    echo "Please check your email inbox for:"
    echo "  Subject: [TIMING REPORT] Re: ... - Pass ${pass_number} Generated"
    echo "  To: All debuggers + manager"
    echo ""
    echo "Generated files:"
    echo "  ${source_dir}/data/${tag}_timing_pass${pass_number}_notify.html"
    echo "  ${source_dir}/data/${tag}_timing_pass${pass_number}_notify.spec"
else
    echo ""
    echo "[ERROR] Email notification failed"
endif

echo "========================================================================"
