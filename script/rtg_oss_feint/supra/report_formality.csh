#!/bin/tcsh
# report_formality.csh - Extract Formality verification results
# Usage: report_formality.csh <tile> <refDir> <tag>
#
# Extracts from FmEqvSynthesizeVsSynRtl reports:
#   - Failing points
#   - Unmatched points (Reference detail + Implementation summary)
#   - Blackbox summary

set tile = $1
set refDir = $2
set tag = $3
set source_dir = `pwd`
touch $source_dir/data/${tag}_spec

# Parse tile (format: tile:umccmd or tile:umcdat)
set tile_name = `echo $tile | sed 's/:/ /g' | awk '{$1="";print $0}' | sed 's/^ //'`

# Parse refDir (format: refDir:/path/to/tile_dir)
set refdir_name = `echo $refDir | sed 's/:/ /g' | awk '{$1="";print $0}' | sed 's/^ //'`

# Validate tile_name is not empty
if ("$tile_name" == "" || "$tile_name" == " ") then
    echo "ERROR: tile_name is empty or invalid" >> $source_dir/data/${tag}_spec
    echo "Input tile: $tile" >> $source_dir/data/${tag}_spec
    echo "Usage: $0 tile:<tile_name> refDir:/path/to/tile_dir <tag>"
    echo "Example: $0 tile:umccmd refDir:/proj/.../tiles/umccmd_Jan26162737 20260301"
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
    exit 1
endif

# Validate refdir_name is not empty
if ("$refdir_name" == "" || "$refdir_name" == " ") then
    echo "ERROR: refdir_name is empty or invalid" >> $source_dir/data/${tag}_spec
    echo "Input refDir: $refDir" >> $source_dir/data/${tag}_spec
    echo "Usage: $0 tile:<tile_name> refDir:/path/to/tile_dir <tag>"
    echo "Example: $0 tile:umccmd refDir:/proj/.../tiles/umccmd_Jan26162737 20260301"
    source $source_dir/script/rtg_oss_feint/finishing_task.csh
    exit 1
endif

set tile_dir = "$refdir_name"

# Get tile directory name (e.g., umccmd_Jan26162737)
set tile_dir_name = `basename $tile_dir`

# Output to spec file
set out = "$source_dir/data/${tag}_spec"

# Find FmEqv report directory and check if FM is complete
set fm_dir = "${tile_dir}/rpts/FmEqvSynthesizeVsSynRtl"
set fm_dat = "${fm_dir}/FmEqvSynthesizeVsSynRtl.dat"

# Check if FM is complete by looking for lecResult in .dat file
set fm_complete = 0
if (-f "$fm_dat") then
    grep -q "^lecResult:" "$fm_dat"
    if ($status == 0) then
        set fm_complete = 1
    endif
endif

# If FM not complete, check TileBuilderShow status
if ($fm_complete == 0) then
    # Find GUI directory for TileBuilder
    set tiles_dir = `dirname $tile_dir`
    set gui_dir = `find $tiles_dir -maxdepth 1 -type d -name "*_GUI" | head -1`

    if ("$gui_dir" == "" || ! -f "${gui_dir}/revrc.main") then
        echo "ERROR: GUI directory not found in $tiles_dir"
        source $source_dir/script/rtg_oss_feint/finishing_task.csh
        exit 1
    endif

    # Run TileBuilderShow to check FM status
    set tb_status_log = "/tmp/tb_status_fm_$$.log"
    cd $gui_dir
    TileBuilderTerm -x "cd $tile_dir; TileBuilderShow >& $tb_status_log"
    cd $source_dir

    # Wait for status log to be created
    sleep 5

    # Extract FM status from TileBuilderShow output
    set fm_tb_status = "UNKNOWN"
    if (-f "$tb_status_log" && -s "$tb_status_log") then
        set fm_tb_status = `grep "FmEqvSynthesizeVsSynRtl" $tb_status_log | awk '{print $NF}'`
        if ("$fm_tb_status" == "") then
            set fm_tb_status = "NOT FOUND IN TILEBUILDER"
        endif
    endif
    rm -f $tb_status_log

    # Handle based on status - start FM if NOTRUN, or monitor if RUNNING
    if ("$fm_tb_status" == "NOTRUN") then
        echo "FmEqvSynthesizeVsSynRtl is NOTRUN - Starting..."
        cd $gui_dir
        source $source_dir/script/rtg_oss_feint/lsf_tilebuilder.csh
        TileBuilderTerm -x "cd $tile_dir; serascmd -find_jobs 'name=~FmEqvSynthesizeVsSynRtl dir=~$tile_dir_name' --action run"
        cd $source_dir
        set fm_tb_status = "RUNNING"
    else if ("$fm_tb_status" == "RUNNING") then
        echo "FmEqvSynthesizeVsSynRtl is already RUNNING - Monitoring..."
    endif

    # Monitor FM task until completion (PASSED/WARNING/FAILED)
    if ("$fm_tb_status" == "RUNNING") then
        echo "Monitoring FmEqvSynthesizeVsSynRtl (checking every 15 min, max 3 hours)..."
        set fm_elapsed = 0
        set fm_done = 0

        while ($fm_done == 0)
            sleep 900
            @ fm_elapsed += 900

            # Check status every 15 minutes
            set tb_status_log = "/tmp/tb_status_fm_$$.log"
            cd $gui_dir
            TileBuilderTerm -x "cd $tile_dir; TileBuilderShow >& $tb_status_log"
            cd $source_dir
            sleep 5

            if (-f "$tb_status_log" && -s "$tb_status_log") then
                set fm_tb_status = `grep "FmEqvSynthesizeVsSynRtl" $tb_status_log | awk '{print $NF}'`
                rm -f $tb_status_log

                if ("$fm_tb_status" == "PASSED" || "$fm_tb_status" == "WARNING") then
                    echo "FmEqvSynthesizeVsSynRtl $fm_tb_status after ${fm_elapsed}s"
                    set fm_done = 1
                else if ("$fm_tb_status" == "FAILED") then
                    echo "FmEqvSynthesizeVsSynRtl FAILED after ${fm_elapsed}s"
                    set fm_done = 1
                else
                    echo "FmEqvSynthesizeVsSynRtl still $fm_tb_status... (${fm_elapsed}s)"
                endif
            endif

            # Timeout after 3 hours (only if not done)
            if ($fm_done == 0 && $fm_elapsed >= 10800) then
                echo "ERROR: FM timeout after 3 hours"
                source $source_dir/script/rtg_oss_feint/finishing_task.csh
                exit 1
            endif
        end
    endif

    # Check final status
    if ("$fm_tb_status" == "FAILED") then
        echo "FmEqvSynthesizeVsSynRtl FAILED - Writing failure report..."

        # Write failure report to spec file
        set fm_log = "${tile_dir}/logs/FmEqvSynthesizeVsSynRtl.log.gz"

        echo "#text#" > $out
        echo "FORMALITY REPORT: $tile_dir_name" >> $out
        echo "" >> $out
        echo "#table#" >> $out
        echo "Item,Value" >> $out
        echo "Tile,$tile_name" >> $out
        echo "Directory,$tile_dir_name" >> $out
        echo "Overall Status,FAILED" >> $out
        echo "FmEqvSynthesizeVsSynRtl Status,FAILED" >> $out
        echo "Log File,$fm_log" >> $out
        echo "#table end#" >> $out
        echo "" >> $out

        source $source_dir/script/rtg_oss_feint/finishing_task.csh
        exit 1
    endif

    # Wait for reports to be generated
    echo "Waiting for FM reports to be generated..."
    set report_wait = 0
    while (! -d "$fm_dir" && $report_wait < 300)
        sleep 10
        @ report_wait += 10
    end

    if (! -d "$fm_dir") then
        echo "ERROR: FM reports not generated after ${report_wait}s"

        # Write error to spec file
        echo "#text#" > $out
        echo "FORMALITY REPORT: $tile_dir_name" >> $out
        echo "" >> $out
        echo "#table#" >> $out
        echo "Item,Value" >> $out
        echo "Tile,$tile_name" >> $out
        echo "Directory,$tile_dir_name" >> $out
        echo "Overall Status,ERROR" >> $out
        echo "Issue,FM reports directory not created after ${report_wait}s" >> $out
        echo "#table end#" >> $out

        source $source_dir/script/rtg_oss_feint/finishing_task.csh
        exit 1
    endif
endif

# Define report files
set failing_rpt = "${fm_dir}/FmEqvSynthesizeVsSynRtl__failing_points.rpt.gz"
set unmatched_rpt = "${fm_dir}/FmEqvSynthesizeVsSynRtl__unmatched_points.rpt.gz"
set blackbox_rpt = "${fm_dir}/FmEqvSynthesizeVsSynRtl__black_box.rpt.gz"
set fm_dat = "${fm_dir}/FmEqvSynthesizeVsSynRtl.dat"

#------------------------------------------------------------------------------
# EXTRACT DATA FROM REPORTS
#------------------------------------------------------------------------------
# Determine failing points status first
if (-f "$failing_rpt") then
    set failing_check = `zcat "$failing_rpt" | grep -c "No failing compare points"`
    if ($status != 0) set failing_check = 0
    if ($failing_check > 0) then
        set failing_count = 0
        set failing_status = "CLEAN"
    else
        set failing_count = `zcat "$failing_rpt" | grep -E "^[0-9]+ Failing" | awk '{print $1}'`
        if ("$failing_count" == "") then
            set failing_count = 0
            set failing_status = "CLEAN"
        else
            set failing_status = "FAILED"
        endif
    endif
else
    set failing_count = "N/A"
    set failing_status = "REPORT NOT FOUND"
endif

# Determine unmatched points
if (-f "$unmatched_rpt") then
    set unmatched_summary = `zcat "$unmatched_rpt" | grep -E "^[0-9]+ Unmatched"`
    if ("$unmatched_summary" != "") then
        set total_unmatched = `echo "$unmatched_summary" | awk '{print $1}'`
        set ref_unmatched = `echo "$unmatched_summary" | sed 's/.*(\([0-9]*\) reference.*/\1/'`
        set impl_unmatched = `echo "$unmatched_summary" | sed 's/.*reference, \([0-9]*\) implementation.*/\1/'`
    else
        set total_unmatched = 0
        set ref_unmatched = 0
        set impl_unmatched = 0
    endif
else
    set total_unmatched = "N/A"
    set ref_unmatched = "N/A"
    set impl_unmatched = "N/A"
endif

# Determine blackbox counts
if (-f "$blackbox_rpt") then
    set bbox_m = `zcat "$blackbox_rpt" | grep -E "^m\s+" | wc -l`
    set bbox_i = `zcat "$blackbox_rpt" | grep -E "^i\s+" | wc -l`
    set bbox_s = `zcat "$blackbox_rpt" | grep -E "^s\s+" | wc -l`
    set bbox_u = `zcat "$blackbox_rpt" | grep -E "^u\s+" | wc -l`
    set bbox_e = `zcat "$blackbox_rpt" | grep -E "^e\s+" | wc -l`
    set bbox_cp = `zcat "$blackbox_rpt" | grep -E "^cp\s+" | wc -l`
    @ bbox_total = $bbox_m + $bbox_i + $bbox_s + $bbox_u + $bbox_e + $bbox_cp
else
    set bbox_total = "N/A"
    set bbox_m = 0
    set bbox_i = 0
    set bbox_u = 0
endif

# Determine overall status from .dat file (lecResult and exitVal)
set overall_status = "UNKNOWN"
set lec_result = ""
set exit_val = ""
set num_noneq = ""
set num_eq = ""

if (-f "$fm_dat") then
    set lec_result = `grep "^lecResult:" "$fm_dat" | awk '{print $2}'`
    set exit_val = `grep "^exitVal:" "$fm_dat" | awk '{print $2}'`
    set num_noneq = `grep "^numberOfNonEqPoints:" "$fm_dat" | awk '{print $2}'`
    set num_eq = `grep "^numberOfEqPoints:" "$fm_dat" | awk '{print $2}'`

    if ("$lec_result" == "SUCCEEDED" && "$exit_val" == "0") then
        set overall_status = "PASS"
    else if ("$lec_result" == "FAILED" || "$num_noneq" != "0") then
        set overall_status = "FAIL"
    else
        set overall_status = "UNKNOWN"
    endif
else
    # Fallback to failing_count if .dat file not found
    if ("$failing_count" == "0") then
        set overall_status = "PASS"
    else if ("$failing_count" != "N/A" && "$failing_count" != "0") then
        set overall_status = "FAIL"
    endif
endif

# Summary table
echo "#text#" > $out
echo "FORMALITY REPORT: $tile_dir_name" >> $out
echo "#table#" >> $out
echo "Item,Value" >> $out
echo "Tile,$tile_name" >> $out
echo "Directory,$tile_dir_name" >> $out
echo "Overall Status,$overall_status" >> $out
if ("$lec_result" != "") then
    echo "LEC Result,$lec_result" >> $out
endif
if ("$num_eq" != "") then
    echo "Equivalent Points,$num_eq" >> $out
endif
if ("$num_noneq" != "") then
    echo "Non-Equivalent Points,$num_noneq" >> $out
endif
echo "Failing Points,$failing_count ($failing_status)" >> $out
echo "Failing Points Report,$failing_rpt" >> $out
if ("$total_unmatched" != "N/A") then
    echo "Unmatched Points,$total_unmatched (Ref: $ref_unmatched / Impl: $impl_unmatched)" >> $out
    echo "Unmatched Points Report,$unmatched_rpt" >> $out
else
    echo "Unmatched Points,N/A" >> $out
endif
if ("$bbox_total" != "N/A") then
    echo "Blackboxes,$bbox_total (Tech: $bbox_m / Interface: $bbox_i / Unresolved: $bbox_u)" >> $out
    echo "Blackbox Report,$blackbox_rpt" >> $out
else
    echo "Blackboxes,N/A" >> $out
endif
echo "#table end#" >> $out
echo "" >> $out

#------------------------------------------------------------------------------
# FAILING POINTS DETAIL (if any)
#------------------------------------------------------------------------------
if ("$failing_count" != "0" && "$failing_count" != "N/A") then
    echo "#text#" >> $out
    echo "FAILING POINTS ($failing_count):" >> $out
    echo "#table#" >> $out
    echo "Type,Path" >> $out
    # Format: "  Ref  BBPin      r:/FMWORK_REF_OSSSYS/osssys/path/to/point"
    # Extract Ref lines only (Impl lines show "None" for unmatched failing points)
    zcat "$failing_rpt" | grep -E "^\s+Ref\s+" | \
        awk -v tile="$tile_name" '{type=$2; path=$3; gsub("r:/[^/]+/" tile "/", "", path); printf "%s,%s\n", type, path}' >> $out
    echo "#table end#" >> $out
    echo "" >> $out
endif

#------------------------------------------------------------------------------
# UNMATCHED POINTS - REFERENCE (Detail)
#------------------------------------------------------------------------------
if ("$ref_unmatched" != "0" && "$ref_unmatched" != "N/A") then
    echo "#text#" >> $out
    echo "REFERENCE UNMATCHED ($ref_unmatched):" >> $out
    echo "#table#" >> $out
    echo "Type,Path" >> $out
    zcat "$unmatched_rpt" | grep -E "^\s+Ref\s+" | \
        awk -v tile="$tile_name" '{type=$2; path=$3; gsub(".*/" tile "/", "", path); printf "%s,%s\n", type, path}' >> $out
    echo "#table end#" >> $out
    echo "" >> $out
endif

#------------------------------------------------------------------------------
# UNMATCHED POINTS - IMPLEMENTATION (Summary by Hierarchy)
#------------------------------------------------------------------------------
if ("$impl_unmatched" != "0" && "$impl_unmatched" != "N/A") then
    echo "#text#" >> $out
    echo "IMPL UNMATCHED ($impl_unmatched) by Hierarchy:" >> $out
    echo "#table#" >> $out
    echo "Type,Hierarchy,Count" >> $out
    zcat "$unmatched_rpt" | grep -E "^\s+Impl\s+" | \
        awk -v tile="$tile_name" '{type=$2; path=$3; gsub(".*/" tile "/", "", path); split(path, arr, "/"); hier=arr[1]; print type, hier}' | \
        sort | uniq -c | sort -rn | \
        awk '{printf "%s,%s,%d\n", $2, $3, $1}' >> $out
    echo "#table end#" >> $out
    echo "" >> $out
endif

#------------------------------------------------------------------------------
# BLACKBOX SUMMARY
#------------------------------------------------------------------------------
if ("$bbox_total" != "N/A") then
    echo "#text#" >> $out
    echo "BLACKBOX SUMMARY:" >> $out
    echo "#table#" >> $out
    echo "Type,Description,Count" >> $out
    echo "m,Technology Macro (.db),$bbox_m" >> $out
    echo "i,Interface-only,$bbox_i" >> $out
    echo "s,User set_black_box,$bbox_s" >> $out
    echo "u,Unresolved ,$bbox_u" >> $out
    echo "e,Empty module ,$bbox_e" >> $out
    echo "cp,Cutpoint blackbox,$bbox_cp" >> $out
    echo "#table end#" >> $out
    echo "" >> $out

    # List non-tech blackboxes if any (i, s, u, e types)
    @ non_tech = $bbox_i + $bbox_s + $bbox_u + $bbox_e
    if ($non_tech > 0) then
        echo "#text#" >> $out
        echo "Non-Tech Blackboxes:" >> $out
        echo "#table#" >> $out
        echo "Type,Design Name" >> $out
        zcat "$blackbox_rpt" | grep -E "^(i|s|u|e)\s+" | awk '{printf "%s,%s\n", $1, $2}' >> $out
        echo "#table end#" >> $out
    endif
endif

exit 0
