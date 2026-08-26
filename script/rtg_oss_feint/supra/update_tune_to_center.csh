# Created on Fri May 25 13:30:23 2023 @author: Simon Chen simon1.chen@amd.com
set tile = $1
set runDir = $2
set refDir = $3
set target = $4
set file = $5
set tag = $6
echo "# Finished params $target $tag"
set source_dir = `pwd`
touch  $source_dir/data/${tag}_spec
rm  $source_dir/data/${tag}_spec
set n_tile = `echo $tile | sed 's/^tile//g' | sed 's/:/ /g' | wc -w`

set tile_filter = ""
if ($n_tile > 0) then
    foreach t (`echo $tile | sed 's/^tile//g' | sed 's/:/ /g'`)
        set tile_owned = `grep "tile," $source_dir/assignment.csv | awk -F "," '{print $2}' | sed 's/\r/ /g'`
        set n_rd_tile = `echo $tile_owned | grep $t | wc -l`
        if ($n_rd_tile == 0) then
        else
            set tile_filter = "$tile_filter $t"
        endif
    end
    set tile = "$tile_filter"
else
    set tile = `grep "tile," $source_dir/assignment.csv | awk -F "," '{print $2}' | sed 's/\r/ /g'`
endif
set n_tile_filter = `echo $tile_filter | wc -w`
if ($n_tile_filter == 0 && $n_tile > 0) then
    echo "I don't own $tile or you may spell the tile wrongly." >> $source_dir/data/${tag}_spec
    set run_status = "failed"
    exit
endif


set targets = "FxUniqNetlist FxFpPlaceMacros FxFpInsertPhysicalCells FxFpGenInternalPowerGrid FxFpInsertPowerGates FxFpFinishPower FxPostFloorPlan FxPlace FxIncrProutePlace FxCts FxIncrProuteCts FxOptCts FxIncrProuteOptCts FxRoute FxOptRoute FxReRoute FxStreamOut"
set n_target = `echo $target | sed 's/:/ /g' | awk '{print $2}' | wc -w`
if ($n_target == 0) then
    source csh/env.csh
    echo "#text#\
    No target specified." >> $source_dir/data/${tag}_spec
    echo "#text#" >> $source_dir/data/${tag}_spec
    exit
endif

cat >> $source_dir/data/${tag}_spec << EOF
#text#
    The tune for $target has been updated to tune Center:
EOF

set target = `echo $target | sed 's/:/ /g' | awk '{print $2}'`
echo "# Finish syntax"
set target_run_dir = ":"
set reply = ""
set n_refDir = `echo $refDir | sed 's/:/ /g' | sed 's/refDir//g' | wc -w`
set n_file = `echo $file | sed 's/:/ /g' | sed 's/file//g' | wc -w`
set n_target = `echo $target | sed 's/:/ /g' | sed 's/target//g' | wc -w`
echo "#list#" >> $source_dir/data/${tag}_spec
#set runDir = `cat $runDir | sed 's/:/ /g' | awk '{print $2}'`
set tuneCenter = `egrep tune assignment.csv | awk -F "," '{print $2}' | sed 's/\r//g'`
echo "tune center: $tuneCenter" >> $source_dir/data/${tag}_spec
foreach t (`echo $tile | sed 's/^tile//g' | sed 's/:/ /g'`)
    echo "# check $t refDir:$n_refDir"
    set run_used = 0
    if ($n_file > 0 && $n_target > 0) then
        if (-e $tuneCenter/$t/tune/$target) then
            foreach f (`echo $file | sed 's/:/ /g' | sed 's/file//g'`)
                if (-e $f) then
                    cp -rf $f $tuneCenter/$t/tune/$target/
                    echo "$f $tuneCenter/$t/tune/$target" >> $source_dir/data/${tag}_spec
                else
                    echo "$f not exist" >> $source_dir/data/${tag}_spec >> $source_dir/data/${tag}_spec
                endif
            end
        else
            mkdir -p $tuneCenter/$t/tune/$target
            foreach f (`echo $file | sed 's/:/ /g' | sed 's/file//g'`)
                if (-e $f) then
                    cp -rf $f $tuneCenter/$t/tune/$target/
                     echo "$f $tuneCenter/$t/tune/$target" >> $source_dir/data/${tag}_spec
                else
                    echo "$f not exist" >> $source_dir/data/${tag}_spec
                endif
            end
        endif
        set run_status = "finished"
    else
        echo "No file or target specified" >> $source_dir/data/${tag}_spec
    endif
    cd $source_dir
    echo "# finish all"
    cd $source_dir
end
source csh/env.csh
cd $source_dir
echo "#line#" >> ${tag}_spec
echo "#text#" >> ${tag}_spec
source csh/env.csh

source csh/updateTask.csh
