---
name: 'Request: Add build recipe for the CNS disk'
about: Suggest that a recipe for putting a specific software CNS disk be added
title: 'Request: recipe to put SOFTWARENAME to the CNS disk'
labels: area-feature.request
assignees: kkm000

---

<!-- Prerequisites:
*** 1. The software should be easily available in source or binary form.
E.g. open source, dotnet or jvm runtime, SRILM easy to license for research.
*** 2. The software may NOT be licensed under GNU Affero (AGPL) license.

Use your judgment: How wide is the use for this software? Unless you are
sending a PR, should we allocate our limited resources to this task?

The process for adding anything to the CNS disk will be documented by v0.7-beta.
If you need to add something right now before it's documented, please go ahead
and still open the issue, even if the addition is not of general inerest. Maybe you can
do it with some guidance from us. If we both try our best, it's not hard to do.
-->

### Please add a recipe for integrating SOFTWARENAME into the CNS disk
The software is used for...

<!-- please provide a Web link, or all available links (GitHub/GitLab/etc repo, homepage, ...) -->
 * Full source/documentation is available at: https://WEBSITE
 * GitHub repo: http://github.com/ADDINFOHERE
 * ...

<!-- Select exactly one of the two options [ ] below as [X]: -->
 - [ ] I will send a PR to add the working recipe into `./lib/build` and path `./lib/build/Millfile`
 - [ ] I'm not qualified to do that, but I believe it is important:

<!-- If you selected the second box, explain your justification below this line -->


<!--
  The user is ultimately in control of what to add or skip to their CNS disk,
  the question is about the default
-->
I think that by default, the software package
 - [ ] Should be built and placed on the CNS disk, as 75% of users use it.
 - [ ] Should not be included by default.

<!--
    If you hesitated with your selection above, or could not decide, speak your heart out,
    and we'll think it through together. In any case, you may add anything you think is important.
-->
