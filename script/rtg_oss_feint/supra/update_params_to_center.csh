# Created on Fri May 25 13:30:23 2023 @author: Simon Chen simon1.chen@amd.com
set tile = $1
set runDir = $2
set refDir = $3
set tag = $4
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


cat >> $source_dir/data/${tag}_spec << EOF
#text#
    The params for $tile has been updated to params center:
EOF

echo "# Finish syntax"
set target_run_dir = ":"
set reply = ""
set n_refDir = `echo $refDir | sed 's/:/ /g' | sed 's/refDir//g' | wc -w`
if (-e  data/$tag.params) then
    set n_params = `cat data/$tag.params | wc -w`
else
    set n_params = 0
endif
if (-e data/$tag.controls) then
    set n_controls = `cat data/$tag.controls | wc -w`
else 
    set n_controls = 0
endif
#set runDir = `cat $runDir | sed 's/:/ /g' | awk '{print $2}'`
set paramsCenter = `egrep params assignment.csv | awk -F "," '{print $2}' | sed 's/\r//g'`
echo "# params center: $paramsCenter" >> $source_dir/data/${tag}_spec
foreach t (`echo $tile | sed 's/^tile//g' | sed 's/:/ /g'`)
    echo "# check $t refDir:$n_refDir $n_params $n_controls"
    set run_used = 0
    if ($n_params > 0 || $n_controls > 0) then
        set paramsCenter = `egrep params assignment.csv | awk -F "," '{print $2}' | sed 's/\r//g'`
        if (-e $paramsCenter/$t) then
            if (-e $paramsCenter/$t/override.params) then 
                if (-e $source_dir/data/$tag.params) then
                    echo "# update params to $paramsCenter/$t/override.params"
                    python $source_dir/py/merge_params.py --origParams $paramsCenter/$t/override.params --newParams $source_dir/data/$tag.params --outParams out.params --op merge
                    cp out.params $paramsCenter/$t/override.params
                    echo "# params" >>  $source_dir/data/${tag}_spec
                    cat $source_dir/data/$tag.params >> $source_dir/data/${tag}_spec
                endif
            else
                cp $source_dir/data/$tag.params $paramsCenter/$t/override.params
                echo "# params" >>  $source_dir/data/${tag}_spec
                cat $source_dir/data/$tag.params >> $source_dir/data/${tag}_spec
            endif
            if (-e $paramsCenter/$t/override.controls) then
                if (-e $source_dir/data/$tag.controls) then
                    echo "# update controls to $paramsCenter/$t/override.controls"
                    echo "# controls" >>  $source_dir/data/${tag}_spec
                    python $source_dir/py/merge_params.py --origParams $paramsCenter/$t/override.controls --newParams $source_dir/data/$tag.controls --outParams out.controls --op merge
                    cp out.controls $paramsCenter/$t/override.controls
                    cat $source_dir/data/$tag.controls >> $source_dir/data/${tag}_spec
                endif
            else
                cp $source_dir/data/$tag.controls $paramsCenter/$t/override.controls
                echo "# controls" >>  $source_dir/data/${tag}_spec
                cat $source_dir/data/$tag.controls >> $source_dir/data/${tag}_spec 
            endif

        else
            mkdir -p $paramsCenter/$t
            if (-e $source_dir/data/$tag.params) then
                cp $source_dir/data/$tag.params $paramsCenter/$t/override.params
                echo "# params" >>  $source_dir/data/${tag}_spec
                cat $source_dir/data/$tag.params >> $source_dir/data/${tag}_spec
            endif
            if (-e $source_dir/data/$tag.params) then
                echo "# controls" >>  $source_dir/data/${tag}_spec
                cp $source_dir/data/$tag.controls $paramsCenter/$t/override.controls
                cat $source_dir/data/$tag.controls >> $source_dir/data/${tag}_spec
            endif
        endif
        set run_status = "finished"
    else
        echo "No params or controls specified" >> $source_dir/data/${tag}_spec
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
