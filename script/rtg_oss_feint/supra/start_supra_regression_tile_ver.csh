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

set project = $1
set tile = $2
set runDir = $3
set disk = $4
set params = $5
set tune = $6
set tag = $7
set table = $8
set refDir = $9
set diskUsage = 0
set diskUsed = ""
set source_dir = `pwd`
set target_run_dir = ":"
set reply = ""
set start_new_run = 0
touch $source_dir/data/${tag}_spec
set n_tile = `echo $tile | sed 's/^tile//g' | sed 's/:/ /g' |  wc -w`
#source csh/env.csh
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

set refDir = `echo $refDir | sed 's/:/ /g' | sed 's/refDir//g'`
#set params = `resolve $params`
cat >> $source_dir/data/${tag}_spec << EOF
#list#
    The TB run for $tile has been started at: 
EOF
set n_params = 0 
set n_files = 0
set eff_rd = ""
if (-e $table) then
    set n_table = `head -n 1 $table | sed 's/|/ /g' | awk '{print NF}'`
    echo "# check table $n_table"
    if ($n_table > 0) then
        python3 $source_dir/py/start_run.py --table $table --arguement $source_dir/arguement.csv --tag $tag
        set n_params = `ls $source_dir/data/$tag.sub*.params | wc -l`
        if ($n_params == 0) then
            set n_params = `ls $source_dir/data/$tag.sub*.controls | wc -l`
        endif
        if (-e $source_dir/data/$tag.sub0.params || -e $source_dir/data/$tag.sub1.params)  then
            set n_params = `ls $source_dir/data/$tag.sub*.params | wc -l`
        endif
        if (-e $source_dir/data/$tag.sub0.controls || -e $source_dir/data/$tag.sub1.controls)  then
            set n_params = `ls $source_dir/data/$tag.sub*.controls | wc -l`
        endif

        if (-e $source_dir/data/$tag.sub0.files || -e $source_dir/data/$tag.sub1.files ) then
            set n_files = `ls $source_dir/data/$tag.sub*.files | wc -l`
            touch data/$tag.runDirFiles
        endif
    else
        set n_params = 0
        echo "# No table used."
    endif
endif
set vto = `cat assignment.csv | grep "vto," | head -n 1 | awk -F ',' '{print $2}' | sed 's/\r//g'`
set rd_valid = 0
echo "#table#" >> $source_dir/data/${tag}_spec
echo "tile,runDir,Params" >> $source_dir/data/${tag}_spec
foreach t (`echo $tile`)
    set rd_valid = 0
    echo "# run for $t $runDir"
    set run_used = 0
    set n_runDir = `cat $runDir | wc -w`
    echo "$n_runDir"
    if ($n_runDir > 0) then
        foreach rd (`cat $runDir`)
            echo "# check $rd."
            set n_rd = `echo $rd | wc -w`
            if ($n_rd == 0) then
                continue
            endif
            if ($rd_valid == 1) then
                continue
            endif
            if (-e $rd/tile.params) then
                set curr_tile = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
            # found the matched tile run
                if ($t == $curr_tile) then
                    set run_used = 1
                    # If use latest run reasonable?
                    echo "# Found ref dir: $rd"
                    set rd_valid = $rd
                endif
            endif
        end
    endif
    set disks = `python3 $source_dir/script/assign_disk.py --csv $source_dir/assignment.csv --tile $t`
    foreach d (`echo $disks | sed 's/:/ /g'`)
        set temp = `df $d | grep -v Filesystem | awk '{print $4}'`
        if ($temp > $diskUsage) then
            set diskUsage = $temp
            set diskUsed = $d
        endif
    end
    if (-e $diskUsed/$vto) then
        cd $diskUsed/$vto
        if (-e $t) then
            cd $t
        else
            mkdir -p $t
            cd $t
        endif
    else
        cd $diskUsed
        mkdir -p $diskUsed/$vto/$t
        cd $diskUsed/$vto/$t
    endif
    # Params in table
    if ($n_params > 0 ) then
        set n_subs = `ls $source_dir/data/$tag.sub*.params | wc -l` 
        if ($n_subs > 0) then
            set subs = `ls $source_dir/data/$tag.sub*.params `
        else
            set subs = `ls $source_dir/data/$tag.sub*.controls`
        endif
        foreach pf (`echo $subs`)
            set sub = `echo $pf | sed 's/\./ /g' | awk '{print $2}'`
            set is_sub_tile = `echo $pf | sed 's/\./ /g' | awk '{print NF}'`
            echo "# is_sub_tile $is_sub_tile"
            if ($is_sub_tile == 4) then
                set sub_tile = `echo $pf | sed 's/\./ /g' | awk '{print $3}'`
                set n_sub_tile = `echo $t | grep $sub_tile | wc -w`
                echo "# $t $sub_tile $n_sub_tile"
                if ($n_sub_tile == 0) then
                    continue
                endif
            endif
            set dir = ${tag}_${sub}
            mkdir $dir
            cd $dir
            echo "### Start run at $diskUsed/$vto/$t/$dir"
            touch override.params
            touch override.controls
            rm override.params
            rm override.controls
 
            echo "NICKNAME = ${tag}_${sub}" > override.params
            echo "TILEBUILDERCHECKLOGS_STOPFLOW   = 0" >> override.controls
            set n_refDir = `echo $refDir | wc -w`
            if ($n_refDir > 0) then
                echo "# Use refDir:$refDir"
                if (-e $refDir/override.params) then
                    cat $refDir/override.params | egrep -v "FORGOTTEN_TARGETS|BRANCHED_|NICKNAME|TILES_TO_RUN" >> override.params
                    cp $refDir/override.params override.refDir.params
                endif
                if (-e $refDir/override.controls) then
                    cat $refDir/override.controls >> override.controls
                endif
            endif

            set paramsCenter = `python3 $source_dir/script/read_csv.py --csv $source_dir/assignment.csv | grep "params," | awk -F "," '{print $2}' | sed 's/\r//g'`
            if (-e $paramsCenter/$t/override.params) then
                sed -i '/NICKNAME/d' $paramsCenter/$t/override.params
                python3 $source_dir/py/merge_params.py --origParams override.params --newParams $paramsCenter/$t/override.params --outParams out.params --op merge
                cp out.params override.params
            endif
            if (-e $paramsCenter/$t/override.controls) then
                python3 $source_dir/py/merge_params.py --origParams override.controls --newParams $paramsCenter/$t/override.controls --outParams out.controls --op merge
                cp out.controls override.controls
            endif
            
            if ($n_subs > 0) then
                cat $pf >> override.params
            endif
            if (-e $source_dir/data/${tag}.${sub}.controls) then
                cat $source_dir/data/${tag}.${sub}.controls >> override.controls
            endif
            echo "# check source dir params"
            if (-e $source_dir/data/$tag.params) then
                cat $source_dir/data/$tag.params | egrep -v "NICKNAME" >> override.params
            endif
            echo "# print final params"
            cat override.params
            echo "# end print final params"

            echo "# print final controls"
            cat override.controls
            echo "# end print final controls"

            setprj $project
            set tb_dir = `pwd`
            set eff_rd = "$eff_rd $tb_dir"
            if (-e $source_dir/script/project/$project/start_env.csh) then
                xterm -e "source $source_dir/script/project/$project/start_env.csh;TileBuilderStart --params override.params --controls override.controls >& $source_dir/data/$tag/${t}_${tag}_${sub}.log;touch ${t}_${tag}.finished" &
            else
                xterm -e "source /tools/aticad/1.0/src/sysadmin/cpd.cshrc;setenv FAMILY supra;setprj $project;TileBuilderStart --params override.params --controls override.controls >& $source_dir/data/$tag/${t}_${tag}_${sub}.log;touch ${t}_${tag}.finished" &
            endif
            cd  $diskUsed/$vto/$t
        end
    else
        echo "# start new run"
        set dir = $tag
        if (-e $dir) then
            cd $dir
        else
            mkdir $dir
            cd $dir
        endif
        echo "### Start run at $diskUsed/$vto/$t/$dir"
        touch override.params
        touch override.controls
        rm override.params
        rm override.controls
        echo "NICKNAME = $tag" > override.params
        echo "TILEBUILDERCHECKLOGS_STOPFLOW   = 0" >> override.controls
        set n_refDir = `echo $refDir | wc -w`
        echo "# check ref run."
        if ($n_refDir > 0) then
            echo "# Use refDir:$refDir"
            if (-e $refDir/override.params) then
                #python3 $source_dir/script/merge_params.py --origParams $refDir/override.params --newParams override.params --outParams out.params --op remove
                #cp out.params override.params
                cat $refDir/override.params | egrep -v "FORGOTTEN_TARGETS|BRANCHED_|NICKNAME|TILES_TO_RUN" >> override.params
                cp $refDir/override.params override.refDir.params
            endif
            if (-e $refDir/override.controls) then
                cat $refDir/override.controls >> override.controls
            endif
        endif
        echo "# check mail params, remove old params from prevous run"
        if (-e $source_dir/data/$tag.params) then
            cat $source_dir/data/$tag.params | egrep -v "NICKNAME" > new.params
            python3 $source_dir/py/merge_params.py --origParams override.params --newParams new.params --outParams out.params --op remove
        endif
        cp out.params override.params
        if (-e $source_dir/data/$tag.controls) then
            python3 $source_dir/py/merge_params.py --origParams override.controls --newParams $source_dir/data/$tag.controls --outParams out.controls --op merge
            cp out.controls override.controls
        endif
        
        echo "# check params center params."
        set paramsCenter = `python3 $source_dir/script/read_csv.py --csv $source_dir/assignment.csv | grep "params," | awk -F "," '{print $2}' | sed 's/\r//g'`
        echo "$paramsCenter/$t/override.params"
        if (-e $paramsCenter/$t/override.params) then
            sed -i '/NICKNAME/d' $paramsCenter/$t/override.params
            python3 $source_dir/py/merge_params.py --origParams override.params --newParams $paramsCenter/$t/override.params --outParams out.params --op merge
            cp out.params override.params
            sed -i '/NICKNAME/d' override.params
            sed -i "1iNICKNAME = $tag" override.params

        endif
        echo "# check params center controls."
        if (-e $paramsCenter/$t/override.controls) then
            python3 $source_dir/py/merge_params.py --origParams override.controls --newParams $paramsCenter/$t/override.controls --outParams out.controls --op merge
            cp out.controls override.controls
        endif

        echo "# check source dir params"
        if (-e $source_dir/data/$tag.params) then
            cat $source_dir/data/$tag.params | egrep -v "NICKNAME" >> override.params
        endif

        echo "# add description"
        set n_description = `grep DESCRIPTION override.params | grep -v "#" | wc -w`
        if ($n_description == 0) then
            if (-e $source_dir/data/$tag/subject.info) then
                set description = `cat $source_dir/data/$tag/subject.info`
                set description = "DESCRIPTION = $description"
                echo $description >> override.params
            endif
        endif
        echo "# print final params"
        cat override.params
        echo "# end print final params"
       
        echo "# print final controls"
        cat override.controls
        echo "# end print final controls"
 
        setprj $project
        echo "# start run"
        if (-e $source_dir/script/project/$project/start_env.csh) then
            xterm -e "source $source_dir/script/project/$project/start_env.csh;TileBuilderStart --params override.params --controls override.controls >& $source_dir/data/$tag/${t}_${tag}.log;touch ${t}_${tag}.finished" &
        else
            if (-e $source_dir/vto_debug) then
                xterm -e "source /tools/aticad/1.0/src/sysadmin/cpd.cshrc;setenv FAMILY supra;setprj $project;TileBuilderStart --params override.params --controls override.controls >& $source_dir/data/$tag/${t}_${tag}.log;touch ${t}_${tag}.finished" &
            else
                xterm -e "source /tools/aticad/1.0/src/sysadmin/cpd.cshrc;setenv FAMILY supra;setprj $project;TileBuilderStart --params override.params --controls override.controls >& $source_dir/data/$tag/${t}_${tag}.log;touch ${t}_${tag}.finished" &
            endif
        endif
        set tb_dir = `pwd`
        set eff_rd = "$eff_rd $tb_dir"
    endif
    cd $source_dir
end

# perform instruction in effective run dir
set tuneCenter = `python3 $source_dir/script/read_csv.py --csv $source_dir/assignment.csv | grep "tune," | awk -F "," '{print $2}' | sed 's/\r//g'`

foreach rd (`echo $eff_rd`)
    cd $rd
    foreach t (`grep TILES_TO_RUN override.params | grep -v "#" |  sort -u | sed 's/TILES_TO_RUN//g' | sed 's/=//g'`)
        set n_wait = 0
        echo "# Go to TB run $rd for |${t}|"
        while(1)
            set run_dir = `ls -1dlar main/pd/tiles/${t}_*_TileBuilder* | tail -n 1 | awk '{print $9}'`
            set n_run_dir = `echo $run_dir | wc -w`
            echo "# ls: No match # is expected, be patience to wait 10~20 min for TB start $n_run_dir"
            if ($n_run_dir > 0 ) then
                set run_dir = `resolve $run_dir`
                echo "# check $run_dir and wait logs/UpdateTunable.log.gz"
                set sub = `grep NICKNAME override.params | grep -v "#" | awk '{print $3}' | sed 's/_/ /g' | sed 's/sub//g' | awk '{print $2}'`
                set n_sub = `echo $sub | wc -w`
                if ($n_sub > 0) then
                    echo "$sub" > $run_dir/$tag.task
                else
                    touch $run_dir/$tag.task
                endif

            #if ($n_files > 0) then
            #    set run_dir = `resolve $run_dir`
            #    echo "$t,$run_dir,$tag.$sub.files" >> $source_dir/data/$tag.runDirFiles
            #endif
                cd $run_dir
                set curr_dir = `pwd | sed 's/\// /g' | awk '{print $NF}'`
                if (-e revrc.main && -e tile.params) then
                    TileBuilderTerm -x "serascmd -find_jobs "status==NOTRUN dir=~$curr_dir" --action run" 
                endif
                cd -
            endif
            if (-e $run_dir/logs/UpdateTunable.log.gz) then
                echo "# $run_dir/logs/UpdateTunable.log.gz is available."
                set params_part = `egrep  "DESCRIPTION" $run_dir/tile.params | grep -v "#" | head -n 1`
                set run_status = "started"
                set target_run_dir = "${target_run_dir}:$run_dir"
                set reply = "The TB run has been started."
                echo "$t,$run_dir,$params_part" >> $source_dir/data/${tag}_spec
                set n_agent_tune = `ls $source_dir/script/project/$project/tune/*/*.tcl | wc -l`
                echo "# Copy agent tune. $n_agent_tune $project"
            
                if ($n_agent_tune > 0) then
                    foreach target_path (`ls -1d $source_dir/script/project/$project/tune/*`) 
                        set target = `echo $target_path | sed 's/\// /g' | awk '{print $NF}'`
                        echo "# $target_path $target"
                        if (-e $run_dir/tune/$target) then
                            foreach tcl_path (`ls $source_dir/script/project/$project/tune/$target/*.tcl`)
                                echo "# copy $tcl_path"
                                set tcl = `echo $tcl_path | sed 's/\// /g' | awk '{print $NF}'`
                                if (-e $run_dir/tune/$target) then
                                    if (-e $run_dir/tune/$target/$tcl) then
                                    echo "cat $tcl_path >> $run_dir/tune/$target/$tcl"
                                        cat $tcl_path >> $run_dir/tune/$target/$tcl
                                    else
                                        echo "cp $tcl_path $run_dir/tune/$target/"
                                        cp $tcl_path $run_dir/tune/$target/
                                    endif
                                endif
                            end
                        else
                            echo "cp -rf  $source_dir/script/project/$project/tune/$target $run_dir/tune/"
                            cp -rf  $source_dir/script/project/$project/tune/$target $run_dir/tune/
                        endif
                    end
                endif
                if ($n_files > 0) then
                    set run_dir = `resolve $run_dir`
                    echo "$t,$run_dir,$tag.sub${sub}.files" >> $source_dir/data/$tag.runDirFiles
                endif

                echo "# Copy tune center tune."
                if (-e ${tuneCenter}/${t}) then
                    echo "# Found tune in tune Center, copying tune."
                    foreach target_path (`ls -1d $tuneCenter/$t/tune/*`)
                        set target = `echo $target_path | sed 's/\// /g' | awk '{print $NF}'`
                        if (-e $run_dir/tune/$target) then
                            foreach tcl_path (`ls $tuneCenter/$t/tune/$target/*.tcl`)
                                set tcl = `echo $tcl_path | sed 's/\// /g' | awk '{print $NF}'`
                                if (-e $run_dir/tune/$target/$tcl) then
                                    cat $tcl_path >> $run_dir/tune/$target/$tcl
                                else
                                    cp $tcl_path $run_dir/tune/$target/
                                endif
                            end
                        else
                            cp -rf  $tuneCenter/$t/tune/$target $run_dir/tune/
                        endif
                    end
                endif

                break
            endif
            set n_wait = `expr $n_wait + 1`
            if ($n_wait > 360) then
                set run_status = "failed"
                echo "$t,$rd, Long time to wait tune." >> $source_dir/data/${tag}_spec
                set target_run_dir = "${target_run_dir}:"            
                break
            endif
            sleep 30
        end
    end
end


echo "# finished start new run."
echo "#table end#" >> $source_dir/data/${tag}_spec

##extract area/timing for FxSynthesize
set blockarea = 1
while ( $blockarea != 0 )
   if ( -e $run_dir/rpts/FxSynthesize/block_area.rpt.gz ) then
      set stdarea = `zgrep "BlockArea" $run_dir/rpts/FxSynthesize/block_area.rpt.gz | tail -n1 | awk '{print $4}'`
      set memarea = `zgrep "BlockArea" $run_dir/rpts/FxSynthesize/block_area.rpt.gz | tail -n1 | awk '{print $6}'`    
      echo "#table#"   >> $source_dir/data/${tag}_spec
      echo "Area,Value" >> $source_dir/data/${tag}_spec
      echo "Standard Area, $stdarea" >> $source_dir/data/${tag}_spec
      echo "Memory Area, $memarea" >> $source_dir/data/${tag}_spec
      echo "#table end#" >> $source_dir/data/${tag}_spec
      set blockarea = 0;
   else
      echo "Block area path are not exist yet : Sleeping"
      sleep 5
   endif
end

set timing = 1
while ( $timing != 0 )
   if ( -e $run_dir/rpts/FxSynthesize/qor.rpt.gz ) then
      set n_tns = `zgrep -m 1 "Total Negative Slack" $run_dir/rpts/FxSynthesize/qor.rpt.gz | awk '{print $4}'|wc -w`
    if ($n_tns > 0) then  
      set wns = `zgrep -m 1 "Critical Path Slack" $run_dir/rpts/FxSynthesize/qor.rpt.gz | awk '{print $4}'`
      set tns = `zgrep -m 1 "Total Negative Slack" $run_dir/rpts/FxSynthesize/qor.rpt.gz | awk '{print $4}'`
      echo "#table#"   >> $source_dir/data/${tag}_spec
      echo "Timing,Value" >> $source_dir/data/${tag}_spec
      echo "Worst Negative Slack,$wns" >> $source_dir/data/${tag}_spec
      echo "Total Negative Slack,$tns" >> $source_dir/data/${tag}_spec
      echo "#table end#" >> $source_dir/data/${tag}_spec
      set timing = 0
    else 
      echo "Please wait, report are not ready yet"
      sleep 5
    endif
   else
      echo "Timing path are not exist yet : Sleeping"
      sleep 5
   endif
end


cd $source_dir
source csh/env.csh
echo "#text#" >> $source_dir/data/${tag}_spec
source csh/updateTask.csh
