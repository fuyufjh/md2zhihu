# 故事的起源

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617865792097-a62a3685-a146-4a8c-9120-25700b7ec34e.png)

在 IT 圈内，“删库跑路”已经成为程序员经常提及的一句玩笑话。虽然是玩笑话，但却反映了数据库内数据对企业的重要性。2020 年的微盟事件就直接让香港主板上市公司微盟集团的市值一天之内蒸发超10亿元，数百万用户受到直接影响。

以小编多年的数据库从业经验而言，删库跑路事件不常有，但因粗心导致的误删数据却略见不鲜。要么手误，要么发布的代码存在bug，导致数据被误删，虽是无心，但是破坏力却也不小。
![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617690420402-f4ac5b23-ba12-45f8-a4a5-5b2a64fd1905.png)

平均每两个月就会有一个类似上面的用户，向我们的值班同学寻求帮助，恢复误删的数据。

对于这些粗心的马大哈，PolarDB-X 是如何帮助他们快速精准的找回丢失数据，拯救他们岌岌可危的工作呢？

首先我们按照操作类型，将误删数据的 Case 进行分类：

-   行级误删，常见指数：5星
    -   使用 delete/update 语句误删/改多行数据

-   表级误删，常见指数：3星
    -   使用 drop table 误删除数据表
    -   使用 truncate table 语句误清空数据表

-   库级误删，常见指数：1星
    -   使用 drop database 语句误删数据库

PolarDB-X 针对上面几种不同的数据误删场景，打造了多项数据恢复的能力，帮助用户快速恢复数据：

<table>
<tr class="header">
<th style="text-align: center;">PolarDB-X 能力</th>
<th style="text-align: center;">应对场景</th>
<th>功能简介</th>
</tr>
<tr class="odd">
<td style="text-align: center;">SQL 闪回</td>
<td style="text-align: center;">行级误删</td>
<td>针对误删SQL的精确回滚能力</td>
</tr>
<tr class="even">
<td style="text-align: center;">Flashback Query</td>
<td style="text-align: center;">行级误删</td>
<td>针对短时间内误操作的快速回退能力</td>
</tr>
<tr class="odd">
<td style="text-align: center;">Recycle Bin</td>
<td style="text-align: center;">表级误删</td>
<td>针对 DDL 误操作的快速回滚能力</td>
</tr>
<tr class="even">
<td style="text-align: center;">备份恢复（PITR）</td>
<td style="text-align: center;">行级误删 <strong><em>:inline_html表级误删 </em></strong>:inline_html库级误删</td>
<td>针对各种误删，恢复数据库至任意时间点的必备能力</td>
</tr>
</table>

本文作为数据恢复系列的第一篇，将重点介绍 PolarDB-X 针对行级误删场景所打造的 SQL 闪回功能。其它的能力将在后续的文章中详细介绍。

# 事故现场

首先，我们以一个实际误删数据的事故开场。

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617778406945-cc42031a-e2ff-45e2-bf08-4ab446b87cca.png)

我们来梳理下事故的时间线：

-   T1：DBA 小明维护了一张员工表，里面记录着公司的员工信息。
-   T2：Mary因为个人原因离职了，小明需要删除Mary的记录，因此他到数据库里面执行了一条 DELETE 语句，本意是想删除用户 Mary 的记录，但是因为手贱，漏了一个and语句， 导致员工 Ralph 的数据也被意外删除
-   T3：此时业务仍在继续，John 被删除， Tim 和 Jose 被插入到表中。而此时粗心的小明发现了数据被误删，迫切希望恢复数据。

接下来，围绕这一次的数据误删事故，看看是 PolarDB-X 是如何拯救粗心的小明的？

# 现有方案

在介绍 SQL 闪回之前，我们先简单了解下目前主流的数据库是怎么应对这种行级数据误删的。按照恢复方式大致可以分为如下两类：

-   恢复数据至误删除前的时间
-   回滚误删除操作

## 恢复数据至误删除前的时间

### 基于 PITR

Point-in-time Recovery(PITR): 顾名思义就是利用备份文件将数据库恢复到过去任意的时间点。目前主流的数据库都支持该能力。虽然各家数据库 PITR 的实现方式不尽相同，但是整体的思路还是一致的，如下图所示：
![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617698199683-4c872dee-f7d3-4ef3-aa18-6bda170b5b06.png)

首先依赖数据库的全量备份集将数据恢复到过去备份时的时间点（通常每隔几天备份一次），再依赖增量的数据变更记录，恢复数据至需要的时间点。PolarDB-X 的 PITR 的实现思路也是如此，不过由于分布式事务的存在，PolarDB-X 还做了更多的工作来保证分片间的数据一致性，这部分的工作将在后续的文章中详细介绍。

有了 PITR 的能力后，一旦出现数据误删，最直接的想法便是通过 PITR 将数据库恢复到数据被误删前的时间点，这种方案的好处是可以将数据库恢复到用户需要的任意时间点，但是也存在一些问题：

-   **恢复时间长**：由于需要将整个数据库进行恢复，整体耗时较长。即使只误删了100条数据，通过这种方式也需要恢复整个数据库（或者整张表）的数据才行。
-   **额外的存储空间**：出于数据安全考虑，PITR 通常会将数据恢复到一个新的数据库中而并非直接覆盖原库中的数据，这就需要额外的存储空间存储新库的数据，当数据量较大的的场景，这部分开销还是很可观的。
-   **部分业务数据丢失**：以上面的例子来看，误删数据后业务仍在继续读写数据库。如果将数据库恢复到误删前的时刻，误删后的正常业务数据也会丢失。

下图针对我们的事故现场，给出了基于 PITR 恢复到数据误删除前的示例图。从图中可以看出，恢复到 T2 时刻，虽然误删的数据找回来了，但是 T2 ~ T3 范围内正常的业务改动也丢失了。

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617709313946-7250e8d7-b6d5-4228-a125-1c430f33b3b5.png)

### Flashback Query

针对 PITR 恢复时间长的问题，也有很多优化策略，其中比较有代表的是 Oracle 以及 PolarDB-X的 Flashback Query 功能。

Oracle 的 Flashback Query 基于 undo 信息，直接从中读取数据的前镜像构造历史快照，将数据恢复到误删除前的时间点。PolarDB-X 的 Flashback Query 实现类似，也是利用 undo 表的信息，读取历史时间点的数据，不过相对于单机数据库，我们在恢复到过去时间点的时候，还需要考虑到不同数据分片间的数据一致性，敬请期待后续的文章，此处就不展开介绍了。

下面我们以 Oracle  为例对上面的场景进行说明。假如 T2 对应的时间点是： 2021-04-06 19:23:24，那么在 Oracle 中，通过 Flashback Query 功能，我只需要执行下面的 SQL，便能查询到 2021-04-06 19:23:23 时刻 Employee 表的数据：

```sql
select * from employee 
as of timestamp 
to_timestamp('2021-04-06 19:23:23','YYYY-MM-DD hh24:mi:ss')
```

基于查询到的误删除前的数据，用户便能快速恢复数据。

Flashback Query 这种基于 Undo 信息恢复的方式，大大提高了数据恢复的速度，同时也无需额外的存储空间，相对于PITR，恢复效率更高。但是这种方式也存在两个问题：

-   **部分业务数据丢失**: ** **由于本质上数据仍是恢复到误删前的时间点，该问题仍然存在
-   **时效性问题**：flashback 使用的是 undo 表空间的Undo 数据, 一旦undo数据因为空间压力被清除, 则会出现无法flashback的情况。因此这种方式只能支持较短时间内的数据回滚。

## 回滚误删除操作

既然数据库会通过增量日志来记录数据变更，那么有没有可能直接通过增量日志来回滚误删除操作呢？答案是肯定的，其中比较有代表性的就是 MySQL 的 Binlog Flashback 工具。

当 MySQL 的 binlog format 设置为 row mode 的时候，binlog 中会记录数据行的变更。
![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617718875516-31bcb8c2-c097-4541-86f5-ce6526692c7f.png)
对于上图中的 employee 表，当我执行如下的 delete 语句删除了两行数据后，对应的binlog中的记录是如下图所示：
![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617719288303-8db67d1a-792c-4d44-babf-e29f980b505e.png)
从上图中可以看到，binlog 会记录下被 delete 语句删除的每行数据，update 也是如此。

binlog flashback工具正式基于这样的信息，按照操作的时间范围、操作类型将 binlog 中对应的数据变更进行逆向，生成对应的回滚SQL，进行数据恢复的。

例如对于上面的delete操作，执行的时间是22:21:00, 那么我们只需要在binlog中找到 22:20:59~22:21:01 之间的delete 操作，并将其转换成对应的 insert语句，如下所示，即可找回丢失的数据。

```sql
insert into test.employee values('2', 'Eric Zhang');
insert into test.employee values('3', 'Leo Li');
```

这种基于增量日志回滚操作的恢复方式，恢复速度较快，且因为增量日志的保存时间较长，恢复数据的时效性相对于 Oracle 的 Flashback Query 的方式也较长。但是这种方式也存在一些问题：

-   **回滚范围过大**：现有的 binlog flashback 工具只能通过 SQL 执行时间、SQL 类型等有限的条件在 binlog 中筛选数据并回滚。如果在筛选的时间范围内，有正常的业务操作的话，那也会被回滚。下图在我们事故现场，用过这种恢复方式会存在的问题：

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617720534254-42e3a9cf-9e8b-4fd8-9155-343d596898d1.png)
从上图中看出，当我们使用 flashback 工具对 T2~T3 范围内的所有DELETE操作进行回滚的后，比实际需要恢复的数据多出 1 行。如果需要恢复数据的话，还需要进行人工比对，剔除这部分不需要恢复的数据。而这部分人工剔除的工作往往也比较耗时且容易出错。

# 主角登场 - SQL 闪回

[PolarDB-X SQL 闪回](https://help.aliyun.com/document_detail/108629.html)功能，从实现方式上看属于对误操作进行回滚。不过相对于现有的方案，提供了精确到 SQL 级的回滚能力以及易于上手的操作界面。

## SQL 级的回滚能力

何为精确到 SQL 级的回滚能力，即只针对误操作影响的数据行进行回滚，不影响业务正常的数据变更。

同样以上面的误删场景为例，我们看下 PolarDB-X SQL 闪回是如何对误删操作回滚的？

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617780238194-f417e4e2-9b1b-4b68-98ce-9f3a28a4eeb5.png)
首先每一条在 PolarDB-X 中执行的 SQL 都会分配唯一的身份证号（TraceID），这保证了所有的改动都是可以追溯的。

当我们发现误删数据后，只需要根据误删除 SQL 的 TraceID，通过 SQL 闪回即可精确的找到这条 SQL 误删除数据并进行回滚。如上图所示，我们误操作的 SQL 的 TraceID 是：abcm321, 那么根据这个“身份证号”， SQL 闪回便能精准的找到被这条 SQL 误删除的数据，并生成相应的回滚 SQL。

## 快速上手

说了这么多，SQL 闪回在 PolarDB-X 中具体是如何使用的呢？ SQL 闪回提供了非常便捷的操作方式，只需三步即可完成数据恢复，充分照顾小明焦急的心情。

1.  在 SQL 审计功能中找到误操作 SQL 的 “身份证号”![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617781501958-cafa9c7e-8e09-4bf5-842a-a2bfdaa90537.png)
1.  SQL 闪回页面填写误操作 SQL 执行的大致时间范围和TraceID，提交 SQL 闪回任务即可。![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617782107411-8c5dd1fa-c0cd-4587-bcca-62bc926d3cf3.png)
1.  等待闪回任务完成下载恢复文件进行数据恢复即可。

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X是如何拯救误删数据的你（一）/1617783003976-53e4ac2c-e401-412c-9c1a-50c48b69c73f.png)

> 关于 SQL 闪回的更多功能，可以参考我们的官方文档：[《SQL 闪回》](https://help.aliyun.com/document_detail/108629.html)


# 总结

本文主要围绕数据误删中的行级误删情况，介绍了 PolarDB-X 的 SQL 闪回是如何帮助用户恢复数据的。相对于现有的数据恢复方案，SQL 闪回的 SQL 级的回滚能力以及易于上手的操作界面能够帮助用户更加精准、更加快速地恢复误删数据。

当然，数据安全是一个永恒的话题，针对不同的数据误删场景，PolarDB-X 已经打造了多项利器来保障用户的数据：PITR、Recycle Bin、Flashback Query 等等。后续的文章将对这些能力逐一介绍，敬请期待~

# 参考资料

1.  [Point-in-time recovery - Wikipedia](https://en.wikipedia.org/wiki/Point-in-time_recovery)
1.  [Using Oracle Flashback Technology](https://docs.oracle.com/cd/E11882_01/appdev.112/e41502/adfns_flashback.htm#ADFNS1008)
1.  [Binary Logging Formats](https://dev.mysql.com/doc/refman/5.7/en/binary-log-formats.html)
1.  [MySQL下实现闪回的设计思路 (MySQL Flashback Feature)](http://www.penglixun.com/tech/database/mysql_flashback_feature.html)



Reference:

