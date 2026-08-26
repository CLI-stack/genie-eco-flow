set refDir = $1
set ip = $2
set tile = $3
set CL = $4
set tag = $5
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
echo "#text#"   >> $source_dir/data/${tag}_spec
echo "------TIMING AND AREA REPORT------" >> $source_dir/data/${tag}_spec
perl $source_dir/script/rtg_oss_feint/supra/synthesis_timing_extract_details.pl $refdir_name $date >> $source_dir/data/${tag}_spec
echo "#text#"   >> $source_dir/data/${tag}_spec
echo "-------LOL REPORT-------" >> $source_dir/data/${tag}_spec
perl $source_dir/script/rtg_oss_feint/supra/lol_extractor.pl $refdir_name  >> $source_dir/data/${tag}_spec


cd $source_dir
set run_status = "finished"
source csh/env.csh
source csh/updateTask.csh
