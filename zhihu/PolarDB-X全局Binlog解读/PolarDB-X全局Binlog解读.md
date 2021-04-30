提供“透明分布式”能力，为用户提供近似单机数据库的使用体验，是PolarDB-X孜孜不倦的追求。本篇将要介绍的是PolarDB-X在Data Replication领域的最新力作——全局Binlog，它是“透明分布式”能力的一个典型代表，解决了诸多痛点问题，下面展开介绍。

## 故事起源

故事要从Binlog说起，Binlog是MySQL数据库引入的一个概念，其因数据复制而生，随MySQL分布式能力的演进而不断进化，经历了异步复制(ASynchronous)、半同步复制(Semi-Synchronous)和全同步复制(MGR)几个发展阶段，目前已经是非常成熟的技术。Binlog及其数据复制能力，不仅满足了MySQL体系内的数据复制需求，其更是实现各种数据架构和支撑各种业务场景的“数据驱动器”，简单总结如下：

-   EDA [Event Driven Architecture]
-   CQRS [Command Query Responsibility Segregation）
-   事件溯源 [Event Sourcing]
-   数据恢复《[PolarDB-X 是如何拯救误删数据的你](https://zhuanlan.zhihu.com/p/367137740)》
-   缓存刷新
-   数据集成
-   流式计算
-   灾难备份
-   ... , ...

场景不胜枚举，此处不再展开介绍，显而易见，Binlog的存在，让很多事情变得简单、变得美好！！

## 揭开面纱

#### 用户体感

那么，全局Binlog又是一个怎样的存在呢？下面揭开它的面纱，我们通过两个例子来看看它的模样。

首先连接上PolarDB-X 2.0，比如`mysql -hpxc-xxxxx -uxxx -pxxx`
登录之后，可以直接进行MySQL Binlog的相关操作，如下所示：

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619692214697-c156e208-49ee-4994-8db8-7a1160fd1610.png)

将对应的Binlog文件进行dump下载，可基于mysqlbinlog工具直接解析

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619692226478-e8f20f63-6433-4187-a203-2cc27499ecbb.png)

上面是通过执行`show master status`、`show binlog events`和`mysqlbinlog`命令后，输出的全局Binlog的结构，什么？这不就是MySQL Binlog吗？是的，全局Binlog就是Binlog，PolarDB-X Global Binlog is just Binlog，您可以像使用单机MySQL的Binlog一样，使用分布式数据库的事务日志，无需感知到分布式系统的任何复杂性和内部细节，更重要的是它完全兼容MySQL的Binlog格式和Dump协议，所以

-   您可以在MySQL上执行一条"Change Master ..."命令，快速构建一条以PolarDB-X为Master的主从同步链路
-   您可以使用Alibaba Canal来消费PoarDB-X的Binlog，快速构建一个Data Pipeline
-   您如果准备将MySQL或兼容MySQL的数据库迁移到PolarDB-X，之前围绕Binlog打造的技术体系可无缝对接
-   ... , ...

透明分布式能力是全局Binlog的使命和初心。所谓透明，就是用户不会、也无需感知到系统内部的复杂性，对于全局Binlog来说，可以从两个方面来体现：一是对“接入”透明，我们在Binlog格式上屏蔽了各种内部细节、提供单机事务使用体验，在接入方式上高度兼容MySQL Dump协议；二是对“变化”透明，当系统内部发生HA切换、增加或移除节点、执行分布式DDL等操作时，用户都不必担心是否会影响到基于全局Binlog的消费链路，系统内部设计了一系列的协议和算法来保证全局Binlog的服务能力不受各种变更的影响。如前所述，完全把PolarDB-X看作一个单机MySQL即可。

#### Demo演示

事实胜于雄辩，插播一个视频，来展示一下：
[polardb-x cdc demo-audio-1080p.mp4](https://yuque.antfin.com/attachments/lark/0/2021/mp4/46860/1619771488794-524a91bd-bf3d-40bc-a71b-f0629bb8d693.mp4)

## 架构原理

Global Binlog is just Binlog更像是一句广告语，接下来的篇幅，将正式从技术实现的角度来剖析全局Binlog的全貌。首先，来看一下全局Binlog组件在PolarDB-X整体架构中的位置，PolarDB-X作为一款云原生分布式数据库，其基本架构如图1.1所示（如果想更全面的了解PolarDB-X的产品架构，可参考我们的另外一篇文章《[PolarDB-X 简介](https://zhuanlan.zhihu.com/p/290053012)》以及PolarDB-X推出的其它系列文章）。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619711598630-32ab558d-a3a1-4166-ba4a-51452919c0a8.png)

如上图所示，整个集群由四个子集群组成：

-   CN  : Compute Node (计算节点)
-   DN  : Data Node (存储节点)
-   CDC  : Change Data Capture (CDC节点)
-   GMS  : Global Meta Service (全局元数据服务)

本文主要介绍的全局Binlog是CDC的核心组件，关于CDC后面将有专栏来进行介绍(预告：它是一个兼具数据“流处理”和“批处理”能力的生态设施)，下图展示的是全局Binlog组件的运行时状态图

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619698576049-f81de742-dd9e-4eb2-b2eb-dd54e161bcbd.png)

上图中展示了几种类型的链路，分别是

-   SQL链路：CN节点接收SQL请求，并进行全局事务控制，最终在各个DN节点进行commit，并产生分片局部的原始Binlog
-   全局Binlog生产链路：全局Binlog组件负责将DN节点分片局部的原始Binlog转化为全局Binlog，并对外提供消费能力
-   Dump注册链路：CN节点接收Dump请求，然后将请求转发给全局Binlog组件的Dumper Leader节点
-   全局Binlog消费链路：Dumper Leader节点接收到Dump请求后，将全局Binlog数据源源不断的推送给消费者

其次，来了解一下全局Binlog的基本原理和主要特征。全局Binlog又称为**逻辑Binlog**，它是以**TSO**为排序基准，将多个DN节点的**原始Binlog**中的**局部事务**进行**排序**、**归并**和**合并**，对数据辅以**过滤**和**整形**，最终把分布式事务转化为单机事务日志格式，满足**外部一致性**要求，并兼容MySQL Binlog文件格式和Dump协议的Binlog。基本原理如图2所示，其主要特征有：

-   **排序和归并**其是全局Binlog最基础的能力。通过以TSO为排序基准，首先对各个DN节点的Binlog(相对于逻辑Binlog的命名，我们称DN节点的Binlog为**原始Binlog**或**物理Binlog**)进行局部排序来构建"偏序"集合，然后通过归并排序将“偏序”集合归并为一个“全序”集合，即：保证了事务的有序性。

-   **合并、过滤和整形**其是全局Binlog在排序和归并基础上的能力进阶。一个涉及多个DN节点的分布式事务提交以后，会在每个DN节点分别产生物理Binlog，物理Binlog中包含大量XA类型的Event和PolarDB-X定制化的Private Event。合并模块会以事务ID为基准对原始Binlog进行聚合，对来自各个DN节点的Event进行事务内的排序，然后剔除XA- Event和Private Event的痕迹，最终构建出只保留了单机事务特性的Binlog文件，即：保证了事务的完整性，并剔除了复杂性。

全局Binlog大致实现细节

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619448863572-b6d1d60e-2db6-45ad-ba38-4f53862b6ce6.png)

## 深入介绍

把复杂留给自己，把简单留给用户，是PolarDB-X团队的核心目标之一。本章节将以问答和举例的方式，来剖析全局Binlog的技术内幕。

#### 什么是TSO

TSO是Timestamp Oracle的简称，它是一个全局逻辑时钟，PolarDB-X的分布式事务便采用了TSO策略，来保证正确的线性一致性和良好的性能，具体可参考文章《[PolarDB-X 强一致分布式事务原理](https://zhuanlan.zhihu.com/p/329978215)》和《[PolarDB-X 全局时间戳服务的设计](https://zhuanlan.zhihu.com/p/360160666)》。PolarDB-X的分布式事务在提交之后，会在事务所涉及到的每个DN节点中产生Binlog Event，除了有常见的XA Start Event、XA Prepare Event和XA Commit Event之外，还会附带一个TSO Event来标识事务的Commit时间，这个TSO Event保存的是一个具体的TSO时间戳，全局Binlog会基于此TSO对事务进行排序。

#### 如何理解偏序和全序

如果对偏序和全序这两个名词比较陌生，建议可以先阅读一下分布式领域的经典论文《Time, Clocks, and the Ordering of Events in a Distributed System》进行科普。先来了解全局Binlog中的偏序，每个DN节点都有自己独立的物理Binlog文件，全局Binlog系统会针对每个DN构造一个Binlog Event Stream，这个Stream中事务的顺序并不是天然按照TSO有序的，所以系统会针对每个DN先进行一次排序，得到若干个局部有序的集合，称之为“偏序”集合(如下图所示)。再来看全序就很好理解了，对于每个分布式事务，参与到该事务的每个DN节点的物理Binlog中记录的事务ID和TSO都是相同的，只需要将所有DN的偏序集合进行多路归并，便可以得到一个全局有序的全序集合(如图2所示)
![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619512606803-6ebefe77-5aa9-4b42-9222-0ea19c852f6b.png)

#### 如何理解外部一致性

如果对“数据一致性”或“外部一致性”不太了解，这里推荐两篇技术文章：《[分布式数据库中的一致性与时间戳](https://zhuanlan.zhihu.com/p/360690247)》和《CockroachDB's Consistency Model》。对于全局Binlog，通俗的来理解，它保证了事务的“完整性”和“有序性”，便满足了外部一致性，而PolarDB-X在没有全局Binlog之前，用户只能直接消费每个DN节点的物理Binlog，此方式既不满足“完整性”也不具备“有序性”，便不能保证外部一致性。

下面通过两个案例来理解外部一致性，案例一是个“转账”场景(如下图所示)，PolarDB-X同步数据到单机MySQL，如果直接同步物理Binlog，则无法保证在MySQL中总是能查询到一致的账户余额，如果是同步全局Binlog，则在MySQL中始终可以查询到一致的账户余额。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619515763895-304b281a-f9a3-4809-a228-ee2787904864.png)

案例二是个“更新拆分列值”的场景(如下图所示)，一条数据的拆分列的值被更新之后，其所属的分片可能会发生变化，变化前后的分片可能属于同一个DN节点，也可能分属于不同的DN节点，本例的场景对应的是后者。当用户提交一条Update SQL，PolarDB-X执行引擎会自动判断该SQL是否涉及到了拆分列值的变化，如果是的话会自动启动分布式事务，将UPDATE转化为DELETE+INSERT的组合操作。比如在本例中，PK=1的某条数据，更新前数据分布在DN1，更新后数据分布在DN2，那么，DN1的物理Binlog中会有一条DELETE Event，DN2的物理Binlog中会有一条INSERT Event，它们归属于同一个事务。在此场景下，如果直接同步物理Binlog，因无法保证DELETE和INSERT之间的顺序，所以可能会导致数据丢失；但如果是同步全局Binlog，系统会保证“DELETE Always happen before INSERT”，这是靠TraceId做到的，在类似拆分键变更这样的场景中，PolarDB-X的执行引擎会按顺序为每个操作标识一个TraceId，全局Binlog在进行事务合并时，会基于TraceId保证事务内的Event之间的顺序。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619517887489-6a6d8c79-1164-4224-935c-682dc5be4f5c.png)

#### 水平扩展和拓扑快照

水平扩展是分布式数据库的核心能力之一，PolarDB-X作为一款云原生分布式数据库，快速水平扩展更是它的强项，依托云的弹性能力，PolarDB-X能够在数分钟内扩展出足够多的CN和DN节点，这种能力为用户带来了巨大的价值，想了解PolarDB-X在水平扩展方向上的技术细节可参考文章《[PolarDB-X 水平扩展](https://zhuanlan.zhihu.com/p/357338439)》。水平扩展的意义显而易见，但对于Binlog消费订阅场景来说，它却是把双刃剑，想象一下在直接消费DN节点的物理Binlog的场景下，当进行水平扩展性时，会是一个怎样的场景？当流量洪峰过去之后，进行水平伸缩时，又是一个什么样的场景？是的，对应的是一套繁琐的运维流程，不仅容易出错，还直接拖慢了系统的伸缩速度，如图6所示：

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619591243326-a61cf4b6-b555-468e-8fcc-778371e37c77.png)

全局Binlog为用户屏蔽了水平扩展时的复杂性，依托全局Binlog，用户可以向上图场景“Say Goodbye”。它是如何做到的？答案是分布式一致性拓扑快照。先来解释一下什么是拓扑，拓扑分为两类：一类是“运行时拓扑”，可以和Flink的Execution Graph Topology进行类比，为了叙述方便，定义英文简称为EGT；一类是“库表元数据拓扑”，熟悉PolarDB-X的读者会比较熟悉，就是执行“show topology ...”命令时返回的元数据拓扑信息，为了叙述方便，定义英文简称为MIT(Meta Information Topology)，为了更形象化的理解，继续看图

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619619708569-d690f654-d4b3-4d75-8458-f338fbf73534.png)

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_eric_38db48f7/zhihu/PolarDB-X全局Binlog解读/1619612612050-128bd769-6b65-404d-bdd0-677ac13c3646.png)

全局Binlog系统的运行时拓扑是一个简单的有向无环图(DAG)，有3种类型的顶点，分别是DN、MergeSource和MergeJoint，DN不再解释，MergeSource担负的主要职责为偏序集合排序、数据整形和过滤，MergeJoint担负的主要职责为全序集合排序和事务合并，在顶点之间流动的是Binlog Events。PolarDB-X的库表元数据拓扑是一个无向图，上图中MIT展示的是PolarDB-X逻辑库内部的最基本的拓扑关系(逻辑库和逻辑分区之间的关系、逻辑分区和物理DB之间的关系、逻辑分区和DN节点之间的对应关系)，如果精细到表级别，拓扑会更加复杂，此处不展开介绍。

回到水平扩展的场景，继续来看全局Binlog的透明平滑变更是如何做到的，答案是靠两个关键操作“打标”和“取标”，通过执行一个分布式事务来进行打标操作，打标的内容视当前上下文而定，事务提交后，在所有DN节点的物理Binlog中都会记录该打标内容，MergeSource和MergeJoint在消费Binlog Event Stream的过程中会完成“取标”操作，针对不同打标内容做不同的处理，核心流程如下：

1.  最开始是一个“初始化”类型的打标，全局Binlog运行时在收到这个标记之后，会完成EGT和MIT的初始化，分别创建一个镜像，并以此次打标事务的TSO为基准记录到Topology Snapshot History表中
1.  新增一个DN节点之后，PolarDB-X内核会感知到DN数量的变化，在这个DN节点正式参与服务前，会先执行一个类型为“DN节点变更”的打标操作，打标内容为最新的DN列表，全局Binlog运行时的MergeJoint节点在收到这个标记之后，会用最新的DN列表创建新的EGT镜像，并以此次打标事务的TSO为基准记录到Topology Snapshot History表中，然后对整个运行时进行重启
1.  新增DN节点就绪之后，PolarDB-X会开始进行分区调度，实现分区分布的再平衡(Rebalance)，在分区数据调度即将完成，新的库表元数据和旧的库表元数据进行Exchange之前，会执行一个类型为“库表元数据变更”的打标操作，打标内容为“变更前的MIT”和“变更后的MIT”，全局Binlog运行时的每个MergeSource节点在收到这个标记之后，会以“变更后的MIT”为准创建新的MIT镜像，并以此次打标事务的TSO为基准记录到Topology Snapshot History表中，并刷新Binlog Event Filter，然后局部重启MergeSource。
    -   各个MergeSource都会去记录Topology Snapshot History，系统会保证幂等性
    -   各个MergeSource的消费进度并一样，在同一时刻，可能有的MergeSource已经消费到了“TSO>300”的位置，有的MergeSource仍然处于“TSO>200 & TSO<300”的位置，但这不会带来任何数据一致性问题，因为打标事务的TSO在各个DN节点都是相等的，所以各个MergeSource有一致的“对齐点”

全局Binlog的“打标和取标”机制，并不仅仅只存在于水平扩展这个场景，在其它很多场景也都有使用，比如在“拆分规则变更”的场景(参见文章《[快速掌握 PolarDB-X 拆分规则变更能力！](https://zhuanlan.zhihu.com/p/367644663)》)，表的拓扑元数据也会发生变化，同样是靠“打标和取标”机制进行的平滑变更。另外，熟悉Flink或流计算的读者，应该会发现，此处介绍的“打标和取标”机制，和分布式快照算法Chandy-Lamport非常类似，感兴趣的读者可参考《Distributed Snapshots: Determining GlobalStates of Distributed Systems》

#### DDL和数据整形

DDL(Schema Change)是关系型数据库绕不开的话题，也是分布式数据库的一个难点课题，想了解PolarDB-X DDL引擎的技术原理可参考文章《[PolarDB-X Online Schema Change](https://zhuanlan.zhihu.com/p/341685541)》。全局Binlog系统对DDL的处理也是靠“打标和取标”机制来实现的，并且也存在一个快照机制——分布式一致性Schema快照，系统会基于快照对Physical Binlog Event进行整形，输出符合标准的Logical Binlog Event，具体细节将在后续文章中进一步介绍。

## 总结展望

#### 性能测试

全局Binlog是一个把多流归并为单流的设计，所以，从架构上来看是存在单点瓶颈的，但这个瓶颈点的水位还是比较高的，对于一般用户和大多数场景来说，并不会轻易触达这个瓶颈点。从我们内部的测试数据来看，对一个4节点的PolarDB-X实例(单个节点配置为8Core32G)进行压测，以有效Binlog Event(有效Event指的是不包括BEGIN和COMMIT这种)为单位来计量TPS的话，每秒可输出的Event数量在25W～30W左右。后续会有专门的文章来详解介绍全局Binlog在性能和稳定性上的一些思考和设计，应对大规模集群的多流方案也已经在路上，敬请期待。

#### 横向对比

<table style="width:100%;">
<colgroup>
<col style="width: 16%" />
<col style="width: 16%" />
<col style="width: 16%" />
<col style="width: 16%" />
<col style="width: 16%" />
<col style="width: 16%" />
</colgroup>
<tr class="header">
<th>CDC能力对比项</th>
<th>PolarDB-X</th>
<th>TiDB</th>
<th>CockroachDB</th>
<th>YugabyteDB</th>
<th>其他(TDSQL/GoldenDB)</th>
</tr>
<tr class="odd">
<td>事务原子性保证</td>
<td>支持</td>
<td>支持</td>
<td>不支持 (行级通知)</td>
<td>不支持 (行级通知)</td>
<td>不支持 (仅支持单分片事务)</td>
</tr>
<tr class="even">
<td>外部一致性保证</td>
<td>支持</td>
<td>支持</td>
<td>不支持</td>
<td>不支持</td>
<td>不支持 (仅支持分片内的局部有序)</td>
</tr>
<tr class="odd">
<td>DDL变更兼容</td>
<td>支持</td>
<td>支持</td>
<td>有限支持</td>
<td>有限支持</td>
<td>不支持</td>
</tr>
<tr class="even">
<td>水平扩容兼容</td>
<td>支持</td>
<td>支持</td>
<td>支持</td>
<td>支持</td>
<td>不支持</td>
</tr>
<tr class="odd">
<td>开源生态数据订阅</td>
<td>兼容MySQL Binlog</td>
<td>Kafka订阅</td>
<td>Kafka订阅</td>
<td>Kafka订阅</td>
<td>Kafka订阅</td>
</tr>
<tr class="even">
<td>开源生态数据同步</td>
<td>兼容MySQL Replication</td>
<td>工具形态支持</td>
<td>不支持</td>
<td>不支持</td>
<td>依赖外部工具(类似DTS)</td>
</tr>
<tr class="odd">
<td>内核级主备复制</td>
<td>兼容MySQL Replication</td>
<td>工具形态支持</td>
<td>支持*</td>
<td>支持*</td>
<td>不支持</td>
</tr>
<tr class="even">
<td>异构库数据同步</td>
<td>Aliyun DTS生态兼容(Oracle/DB2/MySQL/Kafka等)</td>
<td>自建体系(MySQL/TiDB/Kafka)</td>
<td>/</td>
<td>/</td>
<td>类似DTS生态兼容</td>
</tr>
</table>

最后，全局Binlog是PolarDB-X团队精心打磨的一个产品，在分布式数据库Data Replication方向上实现了一些突破，透明分布式能力是它的强项，更重要的是它和MySQL生态的高度兼容，“Global Binlog is just Binlog，Treat PolarDB-X just as MySQL”——这是全局Binlog为用户带来的最大价值。另外，文章的最后预留一个彩蛋，TiDB/CockroachDB/YugabyteDB基于存储层的行级CDC机制构建数据库同步，比如两个分布式数据库集群之间互相复制，会有什么数据一致性问题？

本篇为全局Binlog的开篇文章，后续会有专栏继续揭开全局Binlog的技术内幕，PolarDB-X在Data Replication方向上的其它产品也会相继推出，敬请期待。

## 参考文献

1.  CQRS Pattern[https://martinfowler.com/bliki/CQRS.html](https://martinfowler.com/bliki/CQRS.html)
1.  Time, Clocks, and the Ordering of Events in a Distributed System[https://lamport.azurewebsites.net/pubs/time-clocks.pdf](https://lamport.azurewebsites.net/pubs/time-clocks.pdf)
1.  CockroachDB's Consistency Model[https://www.cockroachlabs.com/blog/consistency-model/](https://www.cockroachlabs.com/blog/consistency-model/)
1.  Architecture of Flink's Streaming Runtime[https://events.static.linuxfound.org/sites/events/files/slides/ACEU15-FlinkArchv3.pdf](https://events.static.linuxfound.org/sites/events/files/slides/ACEU15-FlinkArchv3.pdf)
1.  Flink 原理与实现：架构和拓扑概览[http://wuchong.me/blog/2016/05/03/flink-internals-overview/](http://wuchong.me/blog/2016/05/03/flink-internals-overview/)
1.  Distributed Snapshots: Determining GlobalStates of Distributed Systems[https://lamport.azurewebsites.net/pubs/chandy.pdf](https://lamport.azurewebsites.net/pubs/chandy.pdf)



Reference:

