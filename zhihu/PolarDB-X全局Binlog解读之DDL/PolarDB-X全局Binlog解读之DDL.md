本篇来介绍一下PolarDB-X全局Binog在DDL(Schema Change)这一**问题域**上的一些设计和思考，开始之前，建议优先阅读前序文章《[PolarDB-X 全局 Binlog 解读](https://zhuanlan.zhihu.com/p/369115822)》，该篇文章对全局Binlog的DDL实现预留过一个“彩蛋”，本篇来砸开这颗“彩蛋”。

## Preface

对于任何一款关系型数据库来说，DDL都是一个核心难点问题，上升到分布式数据库，难度则更甚，PolarDB-X作为一款云原生分布式NewSQL数据库，具备完善而强大的DDL处理能力，这种能力体现在各个方面，全局Binlog是其中之一，全局Binlog在DDL上的挑战都有哪些呢，先来看几个问题：

**一致性问题**
我们知道，在分布式的场景下，不同节点的Schema变更是无法做到完全同步的，即DDL变更过程中，不同节点间的Schema是短暂不一致的(但会最终一致)，那么

-   各个节点的Schema不一致，则对应的物理Binlog中的Schema也会存在差异，全局Binlog在进行归并时，如何平滑的兼容这种差异？
-   分布式DDL在各个节点执行完成后，在全局Binlog中体现为一个单机DDL，应该如何优雅的将分布式DDL透明转化为单机DDL？

**兼容性问题**
以兼容性为维度来划分，PolarDB-X的DDL SQL可以划分为两类，一类是和MySQL完全兼容的DDL，此处定义为"公有DDL"，另一类是PolarDB-X个性化的DDL，此处定义为"私有DDL"。全局Binlog兼容MySQL Binlog，这只是它的基本能力，其更高阶的能力是支持PolarDB-X之间的数据同步，也就是说，要在全局Binlog中同时记录"公有"和"私有"DDL，那么，该如何保证消费时互不干扰？

下面带着这些问题，开始本次的探寻。

## DDL In MySQL Replication

全局Binlog是PolarDB-X在Data Replication方向提供的一个兼容MySQL Binlog的生态工具，基于全局Binlog，用户可以把PolarDB-X看作一个单机MySQL，并以其为Master来快速搭建一个主从同步链路。文章开篇，先来简单介绍一下MySQL DDL和Data Replication的一些关系，为后文介绍全局Binlog的DDL方案做一些铺垫。

#### DDL In Binlog

MySQL中一条DDL SQL执行成功之后，对应到Binlog文件中是一个Query Event，这个Event的结构很简单，仅仅是记录了DDL SQL的内容，但其在Binlog文件中的位置却很关键，它是Schema元数据的“分水岭”。以加列操作举例来说，在DDL Event之前的**所有**Binlog Event对应的Schema**一定是**加列之前的元数据，反之亦然

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1621873795473-69abd1df-45ce-47df-80e5-f67afccc9d5d.png)

如图所示，加列之前Binlog Event中记录的table_id为110，加列之后Binlog Event中记录的table_id变为了111，想了解table_id的一些细节，可参看附录[1]和[2]。本文将上述特性定义为DDL的“**串行性**”，串行性看上去是一个很朴素和理所当然的事情，但简单的事情往往是靠复杂的逻辑在支撑，下面来看一下MySQL在保证DDL串行性上的解决方案，最简单的方式是加全局排它锁，对某张表执行DDL操作时禁止所有针对该表的DML SQL，这是MySQL在5.6版本之前的唯一方案，例如对表T进行 DDL操作，大致流程为：

```
依照表 T 的定义新建一个表 T‘
对表 T 加写锁
在表 T’ 上执行 DDL SQL
将 T 中的数据拷贝到 T‘
释放 T 的写锁并删除表 T
将表 T’ 重命名为 T
```

如上方案是“有效”但“低效”的，所以，MySQL从5.6开始引入了支持DDL和DML并发执行的方案，即Online DDL，并在后续版本的演进中，在性能和稳定性上进行了不断的优化，本文将该特性定义为DDL的“**并行性**”。Online DDL不是本篇重点，不展开介绍，主要看一下MySQL中DDL SQL的执行流程，如下所示：

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1622085520256-1bc04482-a1e2-47c4-9119-75d46d61ce77.png)

上图展示的是一个大致的执行流程，实际情况要复杂的多，仅供参考，DDL的执行过程可以分为三个阶段：

**1、准备阶段**

该阶段会依次完成临时frm文件的创建、获取MDL排它锁、确定执行方式、更新内存中的数据字典对象、分配row_log对象记录增量变更、生成新的临时ibd文件等一系列操作。其中执行方式，总结来看，可以划分为3大类：

-   **Copy** : 对于不支持online特性的ddl采用copy方式，比如修改列类型，删除主键等
-   **Online rebuild** : 对涉及数据记录格式变更的ddl，采用Inplace Rebuid的方式，比如添加、删除列、修改列默认值等
-   **Online no-rebuild** : 对只涉及表元数据变更的ddl，采用no-rebuild方式，比如添加、删除索引、修改列名等

**2、执行阶段**

该阶段的主要工作就是按照准备阶段指定的方式去执行，每种方式的执行流程简单总结如下：

-   **Copy** ，在整个执行期间DDL引擎占用的MDL锁为排它锁，即禁止DML操作，并且在数据拷贝的过程中会产生大量的redo和undo log；

-   **Online rebuild** ， 在整个执行期间DDL引擎占用的MDL锁为共享锁，即允许DML并行执行，rebuild期间会以Inplace的模式调整存量数据，然后通过记录和重放增量变更来保证数据的一致性，所谓Inplace指的是在既有的Block上直接变更数据，会涉及数据的重排列和Block分裂等操作，但不会产生redo和undo log，本质上是基于InnoDB引擎对索引数据块的管理机制来实现的，因为一张表就是一个聚簇索引；

-   **Online no-rebuild** ，这个就比较简单了，因为不涉及数据的rebuild，所以可以认为该执行方式在此阶段什么都不做。

**3、提交阶段**

该阶段完成收尾工作，需要持有MDL排它锁，进行新旧元数据的切换，此阶段是保证DDL串行性的关键，对于支持online特性的DDL，会有一个“排空事务”的操作，细节可参见文章《[PolarDB-X：让“Online DDL”更Online](https://zhuanlan.zhihu.com/p/347885003)》

来做个总结：

-   DDL串行性的实现，靠的是MDL锁。对于非online场景，全流程持有排它锁，对于online场景，只在关键阶段持有排它锁，并且理论上持有排它锁的时间会很短，所以才可以称之为online
-   DDL并行性的实现，靠的是InnoDB引擎可以支持Inplace变更，然后辅以增量数据的重放机制，来保证数据的一致性
-   需要补充一点，此处对DDL串行性和并行性的分析，是基于MySQL原生online ddl实现来展开的，业界还有两大开源工具pt-osc和gh-ost可以辅助实现DDL的online操作，实现原理虽然互有差异，但都可以保证DDL的串行性和并行性

#### DDL In Replication

MySQL主从同步(以及MGR全同步)是基于Binlog来实现的，对于数据复制来说，延迟是最为关切的核心指标之一，从Binlog的视角来看，影响复制延迟的两大杀手是“大事务”和“大表DDL”。大事务会导致Binlog文件中瞬间产生大量数据，给下游复制带来压力；DDL SQL在下游复制重放的时候也要保证DDL的串行性，所以上游MySQL如果花费10分钟完成了DDL，那么下游重放也要差不多时间，从而会导致至少10分钟的延迟。

对于大事务来说，可以考虑**非冲突事务并行执行或牺牲事务只保证最终一致**来进行优化，对于大表DDL来说目前还没有特别好的办法，有一种“曲线救国”的方式——在同步过程中忽略掉DDL SQL，通过外部系统维护不同节点之间的同步关系，当需要进行DDL变更时，基于同步关系进行分析来决定DDL变更的顺序，比如对于加列操作，先在下游执行再在上游执行，这样便不会造成同步链路的阻塞，但此方式也有很大的局限性，比如ADD COLUMN AFTER场景

1.  新建一个Mysql主从同步链路，在Master上新建库表，并插入一些数据
    ```
    create database my_test;
    create table my_test.test(
    	id bigint DEFAULT null,
    	name varchar(20) DEFAULT null,
    	age int DEFAULT null
    );
    ```

1.  在从库执行sql：alter table test add column sex varchar(5)  default '男' after name;
1.  在主库test表插入一条记录，观察数据是否可以正常同步，答案是“否”，从库报错如下

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1622104010270-f938fbf7-03ba-45d3-84e0-968ae3941fea.png)

## DDL In PolarDB-X

DDL以及Online DDL是关系型数据库绕不开的话题，更是分布式数据库的一个难点课题，PolarDB-X和MySQL生态高度兼容，在DDL层面也提供了Online DDL的能力，并且有自己一些独特的设计，可以参考下面几篇文章：《[PolarDB-X Online Schema Change](https://zhuanlan.zhihu.com/p/341685541)》《[PolarDB-X 让“Online DDL”更Online](https://zhuanlan.zhihu.com/p/347885003)》《[快速掌握 PolarDB-X 拆分规则变更能力](https://zhuanlan.zhihu.com/p/371381620)》

读完上面所列文章后，可以发现PolarDB-X的Schema可以分为两类：一类是常规意义上理解的Schema，即：库、表、列、索引等；另一类是PolarDB-X特有的Schema，称之为Topology，描述的是库表下的数据分区的组织和分布情况，比如执行一条“show full topology from ...”语句，便可以查看到Topology信息，如下所示：
![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1622108008123-cd2450ea-0c83-4190-bcef-4e8cef909c2f.png) 
那么，对应Topology类型的Schema，便会有一些PolarDB-X“私有”的DDL SQL来进行支持，比如拆分规则变更，如下所示：
![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1622108210042-b896141a-d848-4027-87ad-4a92e13c0f0f.png)

前面介绍了MySQL DDL的执行流程，接下来看一下PolarDB-X DDL的执行流程，基本流程如下所示：
![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1622110563723-c47ee601-99d5-4110-8d0d-8fb57029dcee.png) 
整个执行流程分为两个层次，顶层是Logic Layer，底层是Physical Layer，前者负责控制逻辑DDL的执行流程以及全局元数据的变更，后者负责接收逻辑层派发过来的物理DDL SQL并对分布在各个DN节点上的物理库表进行实际的DDL操作，并且是并行执行的，举例来说：

-   删列场景

Logic Layer会在“变更1”阶段完成元数据的变更并即刻生效(此时外部看到的表结构中已经没有待删除的列)，随后在各个物理库表上执行删列操作(并行执行)，待所有物理删列都执行成功后，结束流程

-   加列场景

Logic Layer会先在各个物理库表上执行加列操作(并行执行)，待所有物理加列都执行成功之后，在“变更2”阶段完成元数据的变更并即刻生效，然后结束流程

Logic Layer和Physical Layer的执行都是Online的，前者依托于一套状态机来保证元数据的平滑变更，后者借助DN节点的Online DDL能力来保证Online，DN节点使用的是阿里云自研的X-DB引擎，在某些方面拥有比MySQL DDL还要强大的Online能力。

此外，PolarDB-X的DDL不仅仅是Online的，在速度上也是非常高效的。首先得益于每个物理分片(表)中的数据量是在一定水位之下的，我们经常吐槽MySQL的DDL慢是因为数量过大导致的，合理使用的话，PolarDB-X的每个物理分片不会存在这样的瓶颈；其次，所有物理分片是并行执行的，DDL SQL的执行时间并不会随物理分片的增多而成比例增加；最后，依托于DN节点的一些优化，在速度上可以提供有力的保证

## DDL In Global-Binlog

来到本文的正题，开始介绍全局Binlog在DDL上的设计和实现。PolarDB-X支持Online DDL，即实现了DDL的并行性特性，那么全局Binlog是如何保证DDL的串行性特性的呢？答案是“打标取标”和“数据整形”，下面展开介绍

关于“打标”，在前序文章中已经介绍过一个水平扩展的案例，在该案例中，通过执行一个特殊的分布式事务进行打标，全局Binlog系统通过“取标”感知到DN节点发生了变更，从而实现运行时拓扑的重建，实现无缝对接。在DDL场景中，具有类似的需求，需要找到一个点，执行一个分布式事务进行“打标”，该事务在所有DN节点都会产生Binlog Event，全局Binlog系统取到该事务所有的Binlog Event，完成合并，并进行全局排序，那么在全局序列中，这个“打标”事务所在的位置便是逻辑DDL Event应该在的位置，即前文所述的那个“分水岭”，最后，将打标事务替换成一个DDL Query Event写入全局Binlog文件，便保证了全局Binlog DDL的**串行性**。 回顾前文PolarDB-X DDL的执行流程图，加入全局Binlog的要素，得到一个新的流程图，如下所示：
![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1622119180801-3ed21cd0-92e7-4d22-881d-c20323308154.png)

DDL打标操作发生在所有物理DDL执行之后，新的Schema元数据生效之前(如果是在变更2进行元数据变更的话)，这是唯一的一个安全点。分析完打标，再来看整形，整形是指对从DN节点获取到的物理Binlog Event进行数据格式上的调整或裁减，为什么需要整形？主要原因有两个：其一，最基本的诉求，Physical Binlog Event中记录的是物理库表的名称，需要将其翻译为PolarDB-X元数据系统中记录的逻辑库表名称才可以对外输出；其二，在DDL执行流程中，打标操作是在所有物理DDL执行之后才进行的，即物理表的Schema变更会先于逻辑表完成，那么全局Binlog系统就会提前收到带有新Schema的Physical Binlog Event，我们必须保证全局Binlog中的Event的结构和当前逻辑表的Schema保持一致，所以必须对Event进行整形，否则同步到下游时会发生异常。如下图所示：
![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1620565475576-1fe37c26-3121-4c59-81eb-88f133d152c6.png)

图中展示了两个场景，加列和删列，加列时需要将Event中新增的列裁剪掉，删列时需要将Event中缺失的列进行补增，那么，整形的依据是什么呢？是基于“**分布式一致性Schema快照**”来做的，全局Binlog运行时会分别为逻辑Schema和物理Schema维护各自独立的快照历史，不管是逻辑DDL，还是物理DDL，每个DDL类型的Event都会被分配一个CTS，然后该CTS为基准，记录Event的Schema信息到到对应的快照历史表中。当收到一条DML类型的Event时，这个Event所属的事务也有一个CTS，系统会分别在逻辑快照历史表和物理快照历史表中查询出小于该CTS的最近一条快照信息，然后解析出Schema结构，对逻辑Schema和物理Schema进行对比，如果存在差异，则以逻辑Schema为标准，对Event进行整形。

下面展示一个具体的数据整形案例。某个CTS为192的事务完成了提交操作，在这个事务中T1表所有分片的数据都发生了变更，基于下图中展示的逻辑快照历史和物理快照历史，整形的流程分析如下

-   TSO为192时，DN-1节点上的d1_000000物理库、d1_000001物理库、d1_000002物理库和DN-2节点上的d1_000004物理库、d1_000005物理库和d1_000006物理库已经完成了加列操作，通过对比，这些库最近有效的物理Schema的结构和逻辑Schema的结构不一致(最近有效的逻辑Schema的TSO为100)，需要删除Event中的ADDR列
-   TSO为192时，DN-1节点上的d1_000003物理库和DN-2节点上的d1_000007物理库还未完成加列操作，通过对比，这些库最近有效的物理Schema的结构和逻辑Schema的结构完全一致(最近有效的逻辑Schema的TSO为100)，所以不需要整形

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1620565507951-c0b2b4ec-f8ea-4651-b493-ca1fe8bb53fc.png)

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1620565487860-4046b037-585a-464a-8ee3-0ea250c34932.png)

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/PolarDB-X全局Binlog解读之DDL/1620565498025-f7cbc15b-0050-48d3-b737-709fe78ed3ca.png)

回到Preface章节的问题，来做个总结：

-   在全局Binlog系统，**打标和快照**是解决很多一致性问题的两大利器，分布式DDL转化为单机DDL是借助分布式事务进行打标来完成的，而不同节点间物理Binlog的差异则是依托快照机制，通过整形来进行解决的
-   关于DDL兼容性问题，此处来给出答案，原理并不难，但实现起来会比较费时费力
    -   如果是100%兼容MySQL的公有DDL SQL，全局Binlog生成一个标准的DDL Event即可
    -   对于私有DDL SQL来说，有两种情况：其一，如果只是部分语法是私有的，如"create table xxx ... dbpartition by ... "，则需要将其"整形"为公有DDL SQL，并将私有DDL SQL转化为Hints，然后生成一个标准的DDL Event，		MySQL在消费到该Event的时候，会忽略Hints，而PolarDB-X在消费到此Event的时候，会以Hints为准；其二，如果整个语法都是私有的，如"alter table dbpartition by ..."，这种SQL不需要让MySQL消费，所以不会生成DDL Event，我们会以一个Rows_Query_Log_Event来记录这个DDL SQL，并加一定的标识，Mysql在消费到该Event的时候，会忽略该Event，PolarDB-X在消费该Event的时候，会识别到标识，然后提取DDL SQL并执行。

全局Binlog DDL的实现原理就介绍到这里，还有一些细分场景不再展开介绍，如：进行拆分键值变更时，物理库表的名称和数量可能都会发生变化，全局Binlog是如何做到Smooth Change的，解决方案和上面介绍的流程基本类似，感兴趣的读者可自行思考一下，欢迎交流。

## Appendix

[1] https://developer.aliyun.com/article/27773
[2] https://dba.stackexchange.com/questions/51873/replication-binary-log-parsingtableid-generation-on-delete-cascade-handling
[3] https://www.microsoft.com/en-us/research/publication/distributed-snapshots-determining-global-states-distributed-system/



Reference:

