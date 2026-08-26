
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
set tune = $4
set tag = $5
set source_dir = `pwd`
set target_run_dir = ":"
set reply = ""
touch $source_dir/data/${tag}_spec

echo "#list#" >> $source_dir/data/${tag}_spec
set n_tile = `echo $tile | sed 's/^tile//g' | sed 's/:/ /g' | wc -w`
set n_tune = `echo $tune | sed 's/:/ /g' | sed 's/tune//g' | wc -w`

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

if ($n_tune == 0) then
    echo "# No tune specified or tune not defined in arguement.csv." >> $source_dir/data/${tag}_spec
    echo "# e.g. add the tune path into arguement.csv: tune/FxFpGenInternalPowerGrid/FxFpGenInternalPowerGrid.userprocs.tcl,tune" >> $source_dir/data/${tag}_spec
    set run_status = "failed"
    exit
endif

cat >> $source_dir/data/${tag}_spec << EOF
#list#
    The commands has been added to tune:
#table#
EOF
set n_refDir = `echo $refDir | sed 's/:/ /g' | sed 's/refDir//g' | wc -w`
echo "Tile,runDir,tune" >> $source_dir/data/${tag}_spec
set eff_rd = ""
foreach t (`echo $tile | sed 's/^tile//g' | sed 's/:/ /g'`)
     if ($n_refDir > 0) then
        foreach rd (`echo $refDir | sed 's/:/ /g' | sed 's/refDir//g'`)
            cd $rd
            set curr_tile = `grep TILES_TO_RUN $rd/tile.params | grep -v "#" | awk '{print $3}'`
            echo "# $t $curr_tile"
            if ($t == $curr_tile) then
            else
                continue
            endif
            if (-e $source_dir/data/${tag}/tune) then
                foreach tune (`ls -1d $source_dir/data/${tag}/tune/*`)
                    echo "$tune"
                    set target = `echo $tune | sed 's/\// /g' | awk '{print $NF}'`
                    if (-e tune/$target) then
                        foreach tcl (`ls $tune/*.tcl | awk -F "/" '{print $NF}' `)
                            echo "$target $tcl"
                            if (-e tune/$target/$tcl) then
                                echo "#  cat $tcl tune/$target/$tcl"
                                chmod 766 tune/$target/$tcl
                                cat $source_dir/data/${tag}/tune/$target/$tcl >> tune/$target/$tcl
                            else
                                echo "#  copy $tcl tune/$target/$tcl"
                                cp -rf $source_dir/data/${tag}/tune/$target/$tcl tune/$target/
                            endif
                        end
                    else
                        mkdir -p tune/$target
                        echo "# cp -rf $source_dir/data/${tag}/tune/$target/* tune/$target/"
                        cp -rf $source_dir/data/${tag}/tune/$target/* tune/$target/
                    endif
                    set cmd =  `ls $source_dir/data/${tag}/tune/*/*.tcl | sed 's/tune\// tune\//g' | awk '{print $2}'`
                    echo "$t,$rd,$cmd" >>  $source_dir/data/${tag}_spec
                    source $source_dir/csh/rerun_target_core.csh $target
                    touch $tag.task
                end
            endif
            set eff_rd = "$eff_rd $rd"
        end
    endif
    cd $source_dir
    foreach rd (`cat $runDir`)
        if ($n_refDir > 0) then
            continue
        endif
        if (-e $rd/tile.params) then
        else
            continue
        endif
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
            if (-e $source_dir/data/${tag}/tune) then
                foreach tune (`ls -1d $source_dir/data/${tag}/tune/*`)
                    set target = `echo $tune | sed 's/\// /g' | awk '{print $NF}'`
                    if (-e tune/$target) then
                        foreach tcl (`ls $tune/*.tcl | awk -F "/" '{print $NF}' `)
                            if (-e tune/$target/$tcl) then
                                chmod 766 tune/$target/$tcl
                                echo "# Append tune to tune/$target/$tcl"
                                cat $source_dir/data/${tag}/tune/$target/$tcl >> tune/$target/$tcl
                            else
                                echo "#  copy $tcl tune/$target/$tcl"
                                cp -rf $source_dir/data/${tag}/tune/$target/$tcl tune/$target/
                            endif
                        end 
                    else
                        mkdir -p tune/$target
                        echo "# Add tune for $target"
                        cp -rf $source_dir/data/${tag}/tune/$target/* tune/$target/
                    endif
                    set cmd =  `ls $source_dir/data/${tag}/tune/*/*.tcl | sed 's/tune\// tune\//g' | awk '{print $2}'`
                    echo "$t,$rd,$cmd" >>  $source_dir/data/${tag}_spec
                    source $source_dir/csh/rerun_target_core.csh $target
                    touch $tag.task
                end
            endif
            set eff_rd = "$eff_rd $rd"
        endif
    end
    cd $source_dir
end
cd $source_dir
echo "#table end#" >> $source_dir/data/${tag}_spec
echo " " >> $source_dir/data/${tag}_spec
set run_status = "finished"
cd $source_dir
source csh/env.csh
echo "#text#" >> $source_dir/data/${tag}_spec
source csh/updateTask.csh
