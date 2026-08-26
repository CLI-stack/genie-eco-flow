# Created on Fri May 25 13:30:23 2023 @author: Simon Chen simon1.chen@amd.com

# Copyright (c) 2024 Chen, Simon ; simon1.chen@amd.com;  Advanced Micro Devices, Inc.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set tile = $1
set runDir = $2
set refDir = $3
set params = $4
set target = $5
set tag = $6
set source_dir = `pwd`
set target_run_dir = ":"
set reply = ""
touch $source_dir/data/${tag}_spec
echo "#list#" >> $source_dir/data/${tag}_spec
set n_tile = `echo $tile | sed 's/^tile//g' | sed 's/:/ /g' | wc -w`
set n_target = `echo $target | sed 's/:/ /g' | sed 's/target//g' | wc -w`
set tile_filter = ""
set n_refDir = `echo $refDir | sed 's/:/ /g' | sed 's/refDir//g' | wc -w`
set tile_owned = `grep "tile," $source_dir/assignment.csv | awk -F "," '{print $2}' | sed 's/\r/ /g'`
if ($n_tile > 0) then
    foreach t (`echo $tile | sed 's/^tile//g' | sed 's/:/ /g'`)
        set n_rd_tile = `echo $tile_owned | grep $t | wc -l`
        if ($n_rd_tile == 0) then
        else
            set tile_filter = "$tile_filter $t"
        endif
    end
    set tile = "$tile_filter"
else
    if ($n_refDir == 0) then
        set tile = `grep "tile," $source_dir/assignment.csv | awk -F "," '{print $2}' | sed 's/\r/ /g'`
        echo "You don't specify any tiles or run dir, do you want to update params for $tile_owned ? " >> $source_dir/data/${tag}_spec
        set run_status = "failed"
        exit
    endif
endif
set n_tile_filter = `echo $tile_filter | wc -w`
if ($n_tile_filter == 0 && $n_tile > 0) then
    echo "I don't own $tile or you may spell the tile wrongly." >> $source_dir/data/${tag}_spec
    set run_status = "failed"
    exit
endif
source $source_dir/script/env.csh
python $source_dir/script/extract_table_info.py --table data/$tag.table --arguement arguement.csv --tag $tag

cat >> $source_dir/data/${tag}_spec << EOF
#list#
    The params has been updated:
#table#
tile,runDir,status
EOF
#set params = `resolve $params`
set eff_rd = ""
set n_table = 0
if (-e data/$tag.table) then
    set n_table = `cat data/$tag.table | wc -w`
    foreach sect (`cat  $source_dir/data/$tag.table | sed 's/|/ /g' | sort -u`)
        set n_run_dir = `echo $sect | egrep "main/pd/tiles" | wc -w`
        if ($n_run_dir > 0) then
            if (-e $sect/tile.params) then
                set eff_rd = "$eff_rd $sect"
                set n_table = 1
            endif
        endif
    end
endif


if ($n_refDir > 0) then
    foreach rd (`echo $refDir | sed 's/:/ /g' | sed 's/refDir//g'`)
        set eff_rd = "$eff_rd $rd"
    end
endif

foreach t (`echo $tile | sed 's/^tile//g' | sed 's/:/ /g'`)
     if ($n_refDir > 0 || $n_table > 0) then
        break
    endif

    foreach rd (`cat $runDir`)
        set curr_tile = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
        if ($t == $curr_tile) then
            cd $rd
            set skip = 0
            if ($refDir == "refDir") then
                echo "# All dir need updated."
            else
                foreach r (`echo $refDir | sed 's/:/ /g' | sed 's/refDir //g'`)
                    set r = `echo $r | sed 's/\/$//g'`
                    if ($r == "$rd") then
                        echo "# found match dir $r $rd"
                        set skip = 0
                    else
                        set skip = 1
                        echo "# not match $r $rd"
                    endif
                end
            endif
            if ($skip == 1) then
                continue
            endif
            set eff_rd = "$eff_rd $rd"
        endif
    end
    cd $source_dir
end

# perform instruction in effective run dir
set update_params = ""
foreach rd (`echo $eff_rd`)
    cd $rd
    echo "# found param file: $source_dir/data/$tag.params"
    set n_params = `cat $source_dir/data/$tag.params | wc -w`
    set n_controls = `cat $source_dir/data/$tag.controls | wc -w`
    set update_params = ""
    set t = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
    if (-e $tag.params) then
        set n_dir_params = `cat $tag.params | wc -w`
        if ($n_dir_params > 0) then
            cat  $tag.params >> override.params
            set ups = `paste -sd ';' $tag.params`
            set update_params = "$update_params;$ups"
        endif
        
    endif
    if (-e $tag.controls) then
        set n_dir_controls = `cat $tag.controls | wc -w`
        if ($n_dir_controls > 0) then
            cat  $tag.controls >> override.controls
            set ups = `paste -sd ';' $tag.controls`
            set update_params = "$update_params;$ups"
        endif
    endif
    if ($n_params > 0) then
        #python $source_dir/py/merge_params.py --origParams override.params --newParams $source_dir/data/$tag.params --outParams out.params --op remove
        #cp out.params override.params
        cat $source_dir/data/$tag.params >> override.params
        set ups = `paste -sd ';' $source_dir/data/$tag.params`
        set update_params = "$update_params;$ups"

    endif
    if ($n_controls > 0) then
        #python $source_dir/py/merge_params.py --origParams override.controls --newParams $source_dir/data/$tag.controls --outParams out.controls --op remove
        #cp out.controls override.controls
        cat $source_dir/data/$tag.controls >> override.controls
        set ups = `paste -sd ';' $source_dir/data/$tag.controls`
        set update_params = "$update_params;$ups"
    endif
    set n_update_params = `echo $update_params | sed 's/\r/ /g' | wc -w`
    if ($n_update_params == 0) then
        set n_update_params = "update params failed"
    endif
    echo "$t,$rd,$update_params" >> $source_dir/data/${tag}_spec
    touch TileBuilderGenParams_$tag.started
    rm TileBuilderGenParams_$tag.started
    TileBuilderTerm -x "TileBuilderGenParams > TileBuilderGenParams.log;touch TileBuilderGenParams_$tag.started"
    touch $tag.task 
end


echo "# Check if TB gen finished."
foreach rd (`echo $eff_rd`)
    cd $rd
    set t = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
    set n_wait = 0
    while(1)
        if (-e TileBuilderGenParams_$tag.started) then
            if (-e TileBuilderGenParams.log) then
                set n_error = `grep -i error TileBuilderGenParams.log | wc -w`
                if ($n_error > 0) then
                    set tbGen_status = `grep -i error TileBuilderGenParams.log | head -n 1`
                else
                    set tbGen_status = "passed"
                endif
            endif
            echo "$t,$rd,TileBuilderGenParams passed" >> $source_dir/data/${tag}_spec
            break
        endif
        set n_wait = `expr $n_wait + 1`
        if ($n_wait > 3600) then
            break
        endif
        sleep 1
    end
end

if ($n_target > 0) then
    foreach rd (`echo $eff_rd`)
        cd $rd
        set targets = `echo $target | sed 's/:/ /g' | sed 's/target//g'`
        TileBuilderTerm -x "TileBuilderOverwriteCommand $targets ;touch TileBuilderOverwriteCommand_$tag.started"
        #foreach tg (`echo $target | sed 's/:/ /g' | sed 's/target//g'`)
        #    TileBuilderTerm -x "TileBuilderOverwriteCommand $tg ;touch TileBuilderOverwriteCommand_$tag.started"
        #    echo "# TileBuilderOverwriteCommand $tg"
        #end
    end
    foreach rd (`echo $eff_rd`)
        cd $rd
        touch $tag.task
        set t = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
        set n_wait = 0
        while(1)
            if (-e TileBuilderOverwriteCommand_$tag.started) then
                echo "$t,$rd,TileBuilderOverwriteCommand passed" >> $source_dir/data/${tag}_spec
                break
            endif
            set n_wait = `expr $n_wait + 1`
            if ($n_wait > 1800) then
                echo "$t,$rd,TileBuilderOverwriteCommand failed in 30 mins" >> $source_dir/data/${tag}_spec
                break
            endif
            sleep 1
        end
    end 
    foreach rd (`echo $eff_rd`)
        cd $rd
        set t = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
        foreach tagt (`echo $target | sed 's/:/ /g' | sed 's/target//g'`)
            source $source_dir/script/rerun_target_core.csh $tagt &
            echo "$t,$rd,$tagt rerun pass" >> $source_dir/data/${tag}_spec 
        end
    end

endif
echo "# sleep 60s for rerun."
set run_status = "started"
echo "#table end#" >> $source_dir/data/${tag}_spec
cd $source_dir
source csh/env.csh
echo "#text#" >> $source_dir/data/${tag}_spec
echo "## Finished update_params "
source csh/updateTask.csh
