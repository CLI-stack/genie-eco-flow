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
set target = $4
set params = $5
set tune = $6
set tag = $7
set table = $8
echo "# Finished params $target"
set source_dir = `pwd`
touch  $source_dir/data/${tag}_spec
set n_tile = `echo $tile | sed 's/^tile//g' | sed 's/:/ /g' | wc -w`
set n_refDir = `echo $refDir | sed 's/:/ /g' | sed 's/refDir//g' | wc -w`
set tile_owned = `grep "tile," $source_dir/assignment.csv | awk -F "," '{print $2}' | sed 's/\r/ /g'`
set tile_filter = ""
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
        echo "You don't specify any tiles or run dir, do you want to rerun for $tile_owned ? " >> $source_dir/data/${tag}_spec
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


set n_target = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print NF}'`
set n_tune = `echo $tune | sed 's/:/ /g' | sed 's/^tune //g' | awk '{print $1}' | wc -w`
set tune = `echo $tune | sed 's/:/ /g' | sed 's/^tune //g' | awk '{print $1}'`
echo "target is $target"
if ($n_target == 0) then
    source csh/env.csh
    echo "#text#\
    No target specified." >> $source_dir/data/${tag}_spec
    echo "#text#" >> $source_dir/data/${tag}_spec
    exit
endif


if ($n_target == 2) then
    set target_from = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print $1}'`
    set target_support = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print $2}'`
endif


cat >> $source_dir/data/${tag}_spec << EOF
#list#
    The $target for $tile has been branched at following dir:
EOF
set n_params = 0
if (-e $table) then
    set n_table = `head -n 1 $table | sed 's/|/ /g' | awk '{print NF}'`
    echo $n_table
    if ($n_table > 0) then
        python3 $source_dir/py/start_run.py --table $table --arguement $source_dir/arguement.csv --tag $tag
        set n_params = `ls $source_dir/data/$tag.sub*.params | wc -l`
    else
        set n_params = 0
        echo "# No table used."
    endif
endif


set params = `resolve data/$tag.params`
echo "# Finish syntax"
set target_run_dir = ":"
set reply = ""
set refDir = `echo $refDir | sed 's/:/ /g' | sed 's/refDir//g'`
echo "#table#" >> $source_dir/data/${tag}_spec
echo "tile,runDir,Params" >> $source_dir/data/${tag}_spec
set baseDirs = ""
if ($n_refDir > 0) then
    foreach baseDir (`echo $refDir | sed 's/:/ /g' | sed 's/refDir//g'`)
        if (-e $baseDir/tile.params) then
        else
            echo "NA,$baseDir ,No tile.params" >> $source_dir/data/${tag}_spec
            continue
        endif
        set t = `grep TILES_TO_RUN $baseDir/tile.params | grep -v "#" | awk '{print $3}'`
        set baseDirs = "$baseDirs $baseDir"
        echo "$t $baseDir"
        set baseDirValid = 1
        set size_params = 0
        set size_controls = 0
        if (-e $source_dir/data/$tag.params) then
            set size_params = `cat $source_dir/data/$tag.params | wc -w`
            if ($size_params > 0) then
                set sub_params = `cat $source_dir/data/$tag.params`
            endif
        endif
        if (-e $source_dir/data/$tag.controls) then
            set size_controls = `cat $source_dir/data/$tag.controls | wc -w`
            if ($size_controls > 0) then
                set sub_params = `cat $source_dir/data/$tag.controls`
            endif
        endif
        echo "$t,$baseDir,based" >> $source_dir/data/${tag}_spec
    end
endif
foreach t (`echo $tile | sed 's/^tile//g' | sed 's/:/ /g'`)
    set run_used = 0
    set baseDirValid = 0
    if ($n_refDir > 0) then
        break
    else  
        # If no run Dir specified, try to find it in run dir list
        foreach rd (`cat $runDir`)
            if ($baseDirValid == 1) then
                continue
            endif
            if (-e  $rd/tile.params) then
                set curr_tile = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
                echo "$t $curr_tile $rd"
                if ($t == $curr_tile) then
                    set baseDirValid = 1
                    set baseDirs = "$baseDirs $rd"    
                    echo "$t,$rd,based" >> $source_dir/data/${tag}_spec
                endif
            else 
                continue
            endif
        end
    endif
    if ($baseDirValid == 0) then
        set reply = "$reply No baseDir for $t\n"
        echo "$t,NA,based" >> $source_dir/data/${tag}_spec
        set run_status = "failed"
        set target_run_dir = "${target_run_dir}:"
        continue
    endif
    cd $source_dir
end
set user_nickname = `cat $source_dir/data/$tag.params | grep "NICKNAME" | awk '{print $3}'`
set n_user_nickname = `echo $user_nickname | wc -w`
if ($n_user_nickname == 0) then
    set user_nickname = ""
endif

foreach rd (`echo $baseDirs`)
    cd $rd
    if ($n_params > 0) then
        foreach pf (`ls $source_dir/data/$tag.sub*.params`)
            set sub = `echo $pf | sed 's/\./ /g' | awk '{print $2}'`
            touch branch_${tag}_${sub}.params
            echo "NICKNAME = ${user_nickname}_branch_${tag}_${sub}" > branch_${tag}_${sub}.params
            cat $pf | egrep -v "NICKNAME"  >> branch_${tag}_${sub}.params
            set sub_params = `cat $pf`
            if ($n_target == 2) then
                set target_from = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print $1}'`
                set target_support = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print $2}'`
                TileBuilderTerm -x "TileBuilderBranch --startfrom $target_from --params branch_${tag}_${sub}.params --noreview --support $target_support;touch branch_${tag}_${sub}.started"
            else
                set target_from = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print $1}'`
                TileBuilderTerm -x "TileBuilderBranch --startfrom $target_from --params branch_${tag}_${sub}.params --noreview;touch branch_${tag}_${sub}.started"
            endif
        end 
        continue
    endif
    echo "# branch run at $rd"
    touch branch_${tag}.params
    echo "NICKNAME = ${user_nickname}_branch_${tag}" > branch_${tag}.params
    # remove double back slash 
    sed -i 's/\\\\/\\/g' $source_dir/data/$tag.params
    cat $source_dir/data/$tag.params | grep -v "NICKNAME" >> branch_${tag}.params
    touch branch_$tag.started
    rm branch_$tag.started
    if ($n_target == 2) then
        set target_from = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print $1}'`
        set target_support = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print $2}'`
        echo "$target_from | $target_support"
        echo "TileBuilderBranch --startfrom $target_from --params branch_$tag.params --noreview --support $target_support;touch branch_$tag.started"
        TileBuilderTerm -x "TileBuilderBranch --startfrom $target_from --params branch_$tag.params --noreview --support $target_support;touch branch_$tag.started"
    else
        set target_from = `echo $target | sed 's/:/ /g' | sed 's/target//g' | awk '{print $1}'`
        TileBuilderTerm -x "TileBuilderBranch --startfrom $target_from --params branch_$tag.params --noreview;touch branch_$tag.started"
    endif

    #xterm -e "source  runBranch.csh" &
end

foreach rd (`echo $baseDirs`)
    cd $rd
    echo "# wait $rd"
    set t = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
    if ($n_params > 0) then
        foreach pf (`ls $source_dir/data/$tag.sub*.params`)
            set sub = `echo $pf | sed 's/\./ /g' | awk '{print $2}'`
            while(1)
                if (-e branch_${tag}_${sub}.started) then
                    break
                endif
                sleep 1
            end
            set run_dir = `ls -1dlar ../${t}_${user_nickname}_branch_${tag}_${sub}_TileBuilder* | tail -n 1 | awk '{print $9}'`
            set n_run_dir = `echo $run_dir | wc -w`
            if ($n_run_dir == 0) then
                set reply = "$reply The run failed to start for $t\n"
                echo "$sub failed,$sub_params" >> $source_dir/data/${tag}_spec
                set run_status = "failed"
                set target_run_dir = "${target_run_dir}:"
            else
                set run_status = "started"
                set run_dir = `resolve $run_dir`
                set target_run_dir = "${target_run_dir}:$run_dir"
                set sub_params = `egrep  "DESCRIPTION" $run_dir/tile.params | grep -v "#" | head -n 1`
                echo "$t,$run_dir,$sub_params" >> $source_dir/data/${tag}_spec
                set reply = "The branch run has been started at: \n $target_run_dir\n"
                cd $run_dir
                if ($n_tune > 0) then
                   echo "# start apply tune $tune"
                   set tune_target = `echo $tune | sed 's/\// /g' | awk '{print $2}'` 
                    if (-e tune/$tune_target) then
                        if (-e $tune) then
                            chmod 744 $tune
                            cat $source_dir/data/$tag/$tune >> $tune
                            echo "# append tune $source_dir/data/$tag/$tune"
                        else
                            cp $source_dir/data/$tag/$tune tune/$tune_target/
                        endif
                    else
                        mkdir -p tune/$tune_target
                        cp $source_dir/data/$tag/$tune tune/$tune_target/
                    endif
                endif
                touch $tag.task
                echo "$sub" | sed 's/sub//g' > $tag.task
                cd -
            endif
            set run_used = 1
        end
        continue
    endif

    while(1)
        if (-e branch_$tag.started) then
            break
        endif
        sleep 1
    end
    set run_dir = `ls -1dlar ../${t}_${user_nickname}_branch_${tag}_TileBuilder* | tail -n 1 | awk '{print $9}'`
    set n_run_dir = `echo $run_dir | wc -w`
    echo "# check branch $run_dir $n_run_dir"
    if ($n_run_dir == 0) then
        set reply = "$reply The run failed to start for $t\n"
        set sub_params = `egrep  "DESCRIPTION" $run_dir/tile.params | grep -v "#" | head -n 1`
        echo "$t,NA,failed" >> $source_dir/data/${tag}_spec
        set run_status = "failed"
        set target_run_dir = "${target_run_dir}:"
    else
        set run_status = "started"
        set run_dir = `resolve $run_dir`
        set target_run_dir = "${target_run_dir}:$run_dir"
        set sub_params = `egrep  "DESCRIPTION" $run_dir/tile.params | grep -v "#" | head -n 1`
        echo "# report run dir $run_dir for $t"
        echo "$t,$run_dir,$sub_params" >> $source_dir/data/${tag}_spec
        cd $run_dir
        if ($n_tune > 0) then
            echo "# start apply tune $tune"
            set tune_target = `echo $tune | sed 's/\// /g' | awk '{print $2}'`
            if (-e tune/$tune_target) then
                if (-e $tune) then
                    chmod 744 $tune
                    cat $source_dir/data/$tag/$tune >> $tune
                    echo "# append tune $source_dir/data/$tag/$tune"
                else
                    cp $source_dir/data/$tag/$tune tune/$tune_target/
                endif
            else
                mkdir -p tune/$tune_target
                cp $source_dir/data/$tag/$tune tune/$tune_target/
            endif
        endif
        touch $tag.task
        cd -
        set reply = "The branch run has been started at: \n $target_run_dir\n"
    endif
    set run_used = 1
end

echo "#table end#" >> $source_dir/data/${tag}_spec
cd $source_dir
echo "#text#" >> $source_dir/data/${tag}_spec
source csh/env.csh
source csh/updateTask.csh
