slurm_pl="bmutils/slurm.pl --config bmutils/slurm.pl.conf"
export train_cmd="$slurm_pl"
export mkgraph_cmd="$slurm_pl --whole-nodes 1"
# egs_cmd needs ~8GB, which means 3/5 of a 5-CPU node. --num_threads is treated
# as a request for the number of cores, so each extraction job gets 3 CPUs (but
# in fact uses 1; the number of CPUs is the proxy for RAM here; we do not track
# node memory allocation in our Slurm setup). The remaining 2 slots may be
# filled by jobs spawned by tran.py at the same time, which generate holdout
# sets, saving the total number of running nodes.
#
# For the C2 machines add no switches, as these sport 8GB of RAM per CPU, and
# can accomodate one egs extraction per CPU. Don't fall for this trap, tho: with
# 2-CPU C2 nodes and '--num-threads 3', the jobs will never start! Slurm is very
# patient, and may hold jobs in the queue forever. If this happens, use the
# scancel command to cancel the stuck jobs before starting over. If using 4-CPU
# C2 nodes, '--num-threads 3' will be extremely inefficient: a whole node will
# be allocated to a job, while the node can comfortably run 4 of them.
#
# Advanced: If preparing to run on differently equipped clusters, you can call
# sinfo with arguments to query what node types are available, and base the
# choice on this. If need help, please ask in the user forum.
export egs_cmd="$slurm_pl --num_threads 3"
unset slurm_pl

# In our scripts we use the dnj_ ("default nj") to assign to various 'nj' or
# 'nj_...'  variables only if they are not otherwise set on the command line,
# using the following pattern to assign the default only if the e.g. nj_dec
# variable was not assigned with the command line switch:
#
# nj_dec=
#
# . common.sh
#
# : ${nj_dec:=$dnj_full}
#
# 48 5-CPU nodes, defined in our default cluster templates, allow for maximum
# simultaneous 240 jobs. Jobs may become too small if the experiment is not
# large, so size accordingly. Normally dnj_full is used for the "full capacity"
# use, and dnj_small to base heavy, parallelized steps, such as i-vector
# extractor training, which consume a whole node.
export dnj_full=160 dnj_small=40
export dnj_dec=$dnj_full

# Use separate defaults for egs extraction/shuffling, which are I/O-intensive,
# so you do not want to many running in parallel. The usual pattern is
#
# egs_nj_opts="--max_jobs_run $egnj_getegs --max_shuffle_jobs_run $egnj_shuffle"
#
# which is then added to train.py --egs.opts= value:
#
#  train.py \
#    --egs.opts="$egs_nj_opts --frames-overlap-per-eg 0 ...."
#    --egs.cmd="$egs_cmd"
#    . . .
export egnj_getegs=30
export egnj_shuffle=100
