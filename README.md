BurrMill
========

**_BurrMill_ is a software suite for cost-efficient number grinding on Google
Cloud Platform.** It has been designed for running [Kaldi experiments](
http://kaldi-asr.org/), but is equally suitable for workloads with a similar
pattern.

Why cloud, and why GCP?
-----------------------

With our Kaldi work, we quickly ran out of capacity of a single machine with a
16-core Skylake-X processor (i9-7960X) and two 1080Ti GPUs. An average trial
experiment took a couple days to train, a relatively large model more than a
week. At this point, the choice everyone faces is either expand in-house
computing capacity, or rent cloud resources from a provider, of which are
currently many.

After some investigation and experimenting, we found that Google Cloud Platform
is the best choice. Two main benefits that put it above other contenders were,
first, a very quick virtual machine staging (average 40 seconds from prepared
disk image to a responsive CPU-only computing node, 80 seconds for a GPU node),
and, second, the availability of _preemptible_ VMs, including GPUs, at a fixed
and a very attractive cost.

If you are considering a high-performance computation that can be expressed as a
succession of **well-parallelizable, relatively short, independently sharded
jobs**, you can use this suite to its best. It was designed and is tuned
primarily for Kaldi experiments, but you can adapt it to any
computationally-intensive load with a similar load pattern. Read on.

### You need to know:

 * The very basics of IP networking, what is SSH, and how it is used to work
   with remote machines. Advanced configuration topics will be covered, but you
   must have used it already.
 * Basics of Un*x shell command line. Assuming you have experience runnig Kaldi,
   you likely know enough.

### You need to have:

 1. Started [the _BurrMill 101_ crash course](https://100d.space/burrmill-101).
   The first post is an introduction, and posts 2 through 7 are walkthroughs.
 2. A Google account, protected with [2-factor authentication](
   https://support.google.com/accounts/answer/185839).
 3. A credit card or other means of setting up a billing account. When you
   first use GCP and enable billing, Google gives you (as of this moment) a
   credit of $300, good for 12 months. This is all covered in _BurrMill 101_.
 3. A Web browser. GCP provides a small Debian-based virtual machine, free of
   charge, which you can use from the browser directly, [for up to 50 hours a
   week](https://cloud.google.com/shell/docs/limitations). This is the most
   secure, and a recommended way to run administrative tools, such as BurrMill.
   Besides, you need the GCP Web interface for the initial setup of GCP and
   billing accounts, for monitoring the performance of your cluster, and one-off
   tasks. But I'm sure you have one.
 4. A computer from which you will connect to the cluster to run experiments,
   with [Google Cloud SDK](
   https://cloud.google.com/sdk/install#installation_options) and an SSH
   terminal emulator. It can be any OS matching the SDK requirements. Cloud
   Shell is not suitable for daily work, and has a usage limit. Linux obviously
   qualifies; For Windows, WSL with a Debian distribution works (but is a bit
   sluggish when running Cloud SDK tools), or a native Windows build of Cloud
   SDK and a Windows-based SSH emulator. There are free emulators [Putty](
   https://www.chiark.greenend.org.uk/~sgtatham/putty/), [Windows Terminal](
   https://www.microsoft.com/p/wt/9n0dx20hk701) and probably other; and a few
   commercial clients. This may provide a better experience that WSL. Mac... I
   do not know anything about them. Chime in and tell me (or, even better, send
   a PR to this file).
 5. Optionally, you can use your own Linux computer if you are extending
   BurrMill-packaged software inventory, and need to debug its build
   process. You can also start a VM in the cloud for that. Regular BurrMill
   builds are performed entirely in the clound, by the Cloud Build service.
 6. Optionally, if you want to run BurrMill commands locally, you need a
   Unix-like system with Bash 4.2+ and a few other tools. For a Mac, this
   means you need [Homebrew](https://formulae.brew.sh/formula/bash#default).
   On Windows, WSL works with it, if a bit sluggish running Cloud SDK commands.


Design goals and constraints
----------------------------

### Lowest possible cost

A new compute node in one of configurations that you define is created on demand
when a new batch is submitted, no current nodes are able to accommodate the
capacity, and the configured number of nodes is not exceeded. The node is
deleted entirely when it's no longer required. You can tune some variables, such
as the common NFSv4 filer machine size and the working disk size/performance,
depending on the size of your experiments.

The power control utility switches between "low" and "full" power (and cost);
you run a computation at the full power, but you may debug your setup, launch
small number (1-3 at a time) of test jobs, and prepare experiments and analyze
results in the low-power mode just fine. The cost of running two machines, the
login and NFS server nodes, in a "low power" mode is $30-$50 a month even if you
leave them on around the clock (you probably won't), and is billed per second of
runtime only for the time it is "powered on," except disks, which are billed as
long as they exist.

The same tool controls the cluster's power on/off state. The transition takes
2-3 minutes, like booting a desktop computer would. You may put the cluster into
a _hibernation state_ by keeping only a snapshot of its main disk in stowage ,
but ready to wake up. This is a recommended mode if you use the _BurrMill_ only
to run some of the larger experiments, and get by your in-house setup
otherwise. The hibernation state incurs some storage charges, but they are quite
small. Transition may take 5 to 20 minutes, depending on the amount of data on
the NFS disk.

### Little or no security inside the firewall

_BurrMill_ has been designed under an assumption of *no role-based or
account-based access control whatsoever,* to achieve the highest possible
throughput. The reasons are explained in the documentation, and have to do with
the way Munge security works in Slurm. All files are stored on the central file
server under the same UID/GID, and are readable and writable by anyone. This is
not a crippling restriction: BurrMill clusters are designed for private use by
an individual or a tight team of coworkers; they are built around a single NFS
server, which has a limited (although quite formidable) throughput. If you
really want to isolate workspaces of more than one team, nothing prevents you
from running multiple clusters, or even multiple projects. Given that GCP is
very flexible (although a bit daunting) in security controls, you may share
computing images and data buckets between teams, and have a separate cluster for
each of them, with independent power controls. If you are after managing muliple
projects with different acess rights, check out [GCP Cloud Identity and
Organizations](
https://cloud.google.com/resource-manager/docs/quickstart-organizations): the
organization is free of charge, you only need to own a domain (you can get one
from the very same Google for $8 a year).

Uh, interesting, but what do all these words mean?
--------------------------------------------------

### Kaldi: workload pattern

[Kaldi](https://kaldi-asr.org/) is a leading toolkit in ASR research. If you
have to ask, then probably what you _really_ want to know is its workload
pattern, and whether adopting it is feasible for you. If you are familiar with
Slurm, Kaldi under _BurrMill_ launches batch jobs, most often arrays, with (our
patched) `sbatch --wait` command, and sends a script to its stdin.

Kaldi experiment scripts are sharding workloads into units of works, mere shell
commands (either simple or pipelines), launch them in the cluster in parallel,
then wait for their completion. Note that *Kaldi does not use MPI;* every
separate machine is churning its own shard of data. This is important, because
any work unit can be restarted independently of others, and that's where the
much cheaper preemptible VM instances really shine.

Another difference from a typical HPC load is that jobs come and go very
quickly, so it is important to waste as little time as possible between jobs. It
is also more efficient to plan for jobs that execute quickly (from seconds to 30
minutes) to take the full advantage of the preemptible VM discounts, at the very
least for computations on GPU, which are expensive.

**Note** that you do not have to use preemptible instances. If your budget
allows, and your jobs require that machines stay alive for a while (e.g., longer
running payloads depending on MPI). You may still use Slurm as usual, and allow
_BurrMill_ to bring the nodes up and down as required by your workload.


### GCP, or Google Cloud Platform

I bet you heard about it. In a nutshell, you rent virtual machines in your
desired configuration, as simple as this. CPU, GPU and RAM are quited per
unit×hour of use but charged at a 1 second granularity, provisioned disks per
GB×hour, storage buckets and snapshots also per GB×hour, but at a lower rate.

It is important that you understand how to optimize your cost by correctly
sizing some items in your setup, and how to secure your computing rig, lest it
be hijacked by cryptocurrency miners. We have [a crash course](
https://100d.space/burrmill-101) to get you up and running.

GCP is overwhelming for a beginner. _BurrMill_ was designed to help with this
complexity, partially by hiding it, partially driving you to understand the
platform.


### Preemptible VMs

GCP has two types of VM runtime policy: permanent and [preemptible](
https://cloud.google.com/compute/docs/instances/preemptible). In either case you
are billed for the total uptime of the machine (CPU, RAM and GPU), but at a very
different rate: preemptible VMs are charged at 30% (±0.5%) the cost of a
permanent VM, including CPU, GPU and RAM. This is a huge advantage for
restartable batch loads!


The permanent machines are not stopped by GCP on their own once booted. GCP can
even migrate a VM during their hardware maintenance, and the move takes less
than a second, so you won't likely even notice. The preemptible machine, on the
other hand, can be stopped by GCP at any time with only 30 seconds of advance
notice: when a hardware maintenance is needed, or, more often, when resources
are requested by other users. The loss rate is in fact very low.

### Slurm

[Slurm](https://github.com/SchedMD/slurm), formerly known as SLURM, is a
resource manager and job scheduler widely used in high-performance computing
(HPC) world to control physical supercomputers. Slurm has enough features for
cloud-based computing to make an efficient use of the cloud environment.

Slurm is open source and GPL, and actively maintained and developed by SchedMD](
https://schedmd.com/); they also provide paid support for supercomputer
operators. Full [Slurm documentation]( https://slurm.schedmd.com/) is available
on their site.

SchedMD also provides a [set of scripts](https://github.com/SchedMD/slurm-gcp)
to run Slurm entirely on GCP, but it's more like a demonstration of the
possibilities than a way to cost-efficiently run day-to-day experiments.


Ballpark costs (Kaldi)
----------------------

In our experience, the largest contributing factor to the total expense was the
charge for the GPUs. As an estimate, a very large TDNN-F model that took 48
hours to train on GPUs, while ramping up its Tesla P100 GPU count from 3 to 18,
and 52 hours total with feature and i-vector extraction, shuffling and decoding
cost about $240. Of these, $190 were charged for the use of 438 GPU-hours. This
is ≈80% of the total, and the rest splits roughly evenly between computing node
CPU, RAM and disk, and (non-preemptible) CPU, RAM and disk of the 3 control
machines.

Another factor is the Tesla P100 is at the least 20% faster under Kaldi training
load than the stock GTX-1080Ti GPU (they share the GPU chip, but P100 has a very
different GRAM), everything else being equal. Given that these factors nearly
cancel out, a training run will cost close to $0.46 per your estimated 1080Ti
GPU-hour, lock, stock and barrel. Put another way, the 20% GPU speedup nearly
absorbs the extra 25% expense of "everything else" but the GPU. YMMV; you'll
correct the cost estimation factor after your first sizable run. Start with
1.05.

As a reference point for the preemptible node loss rate, there were 34 events
altogether during these 52 hours. Given that at times there were 60+ active
nodes, this is quite low. Currently, we are not using the 30-second warning at
all; there is a potential to improve job rescheduling time by listening for it,
which we plan to do eventually.

We are experimenting with training on the T4 GPUs, offered at an obscenely low
price of $0.11/hour. This may be the best choice if you are learning on your own
and paying out of your own pocket. Comparison will be linked to from here soon,
but being 4 times cheaper, they are certainly far from being 4 times slower!


Documentation
-------------

...is in progress. If you have no or little experience with GCP, you should use 
read [the _BurrMill 101_ crash course](https://100d.space/burrmill-101) before
even attempting to set up your GCP account (yes, there are more and less
convoluted ways!). I am writing more in the same blog, with the idea that this
will eventually develop into the documentation in this repository.

If you know enough of GCP and are eager to start experimenting deeper, feel free
to join the [BurrMill Q&A forum](
https://groups.google.com/forum/#!forum/burrmill-users), so that the
communication will be in the open and available to other early adventurers.
And, needless to say, helping me write the documentation would be awesome!

It goes without saying that collaboration on any part is more than welcome!

---
_BurrMill_ is licensed under the [Apache License, Version 2.0](LICENSE)  
Copyright 2020 Kirill 'kkm' Katsnelson  
Copyright 2020 BurrMill Contributors
