# 谈谈 PolarDB-X 的水平扩展

## 引言

水平扩展（Scale Out）对于数据库系统是一个重要的能力。采用支持 Scale Out 架构的存储系统在扩展之后，从用户的视角看起来它仍然是一个单一的系统，对应用完全透明，因此，它可以使数据库系统能有效地应对不同的负载场景，对用户非常用价值。

但是，数据库本身是一个有状态的系统，所以，它的水平扩展是一件比较困难的事情。数据库通常需要管理着庞大的数据，系统在扩展期间，如何保证数据一致性、高可用以及系统整体的负载均衡，更是整个水平扩展的难点。

水平扩展按不同资源类型分类，可以细分为计算节点的水平扩展与数据节点的水平扩展，后文若无特别说明，水平扩展特指数据节点的水平扩展。而数据节点的水平扩展，按查询请求的类型，也可以进一步划分为读能力的扩展与写能力的扩展。

## 单机数据库的扩展

### MySQL 主从复制

在单机数据库时代，数据库的读写流量全集中在一台物理机。所以，单机数据库要做扩展,  一个简单有效的思路，就是将单机数据库的数据里复制一份或多份只读副本，然后应用自己做读写分离。

早期 MySQL（5.5及以下版本）基于主从复制协议实现了主备库架构[17]，依靠备库实现了读能力的扩展，但主库与备库之间同步是采用异步复制或半同步复制，备库的数据总会有一定数据延迟（毫秒级或亚秒级）。

### MGR 与 多主模式

后来 MySQL 在5.7引入了基于Paxos协议[14]的状态机复制技术：组复制[13]功能，彻底解决了基于传统主备复制中数据一致性问题无法保证的情况。组复制使MySQL可以在两种模式下工作：

-   单主模式(Single-Master)。单主模式下，组复制具有自动选主功能，每次只有一个 Server成员接受写入操作，其它成员只提供只读服务，实现一主多备。
-   多主模式(Multi-Master)。多主模式下，所有的 Server 成员都可以同时接受写入操作，没有主从之分，数据完全一致，成员角色是完全对等的。

但是，无论是单主模式还是多主模式，都只能支持读能力的扩展，无法支持写能力的扩展（事实上，MGR的多主模式更多的作用是用于高可用与容灾）。原因很好理解，即使在多主模式下，每个Server节点内实际所接收的写流量（来自客户端写流量+来自Paxos协议的复制流量）是大致相同的。随着Paxos Group的成员增多，写放大的现象将越来越严重，将大大影响写吞吐。此外，MGR采用乐观冲突检测机制来解决不同节点的事务冲突，因此在冲突频繁的场景下可能会出现大量事务回滚，对稳定性影响很大。

## 分布式数据库的扩展

与单机数据库不同，分布式数据库本身就是为了解决数据库的扩展问题而存在。比如, 目前相对主流的以Google Spanner[10]、CockroachDB[5]、TiDB[4]等为代表NewSQL[9]数据库，大多都是基于Shared-Nothing架构，并对数据进行了水平分区，以解决读写扩展问题；每个分区又通过引入Raft[14]/Paxos[15]等的一致性协议来实现多副本的强一致复制，并以此来解决分区的高可用与故障容灾问题。因此，水平扩展在分布式数据库中是一个重要而基础能力。

这里将以 CockroachDB  为例来探讨分布式数据库的水平扩展过程。CockroachDB 是一个参考Google Spanner[10]论文的实现的开源的 NewSQL 数据库。一个 CockroachDB 集群是由多个 Cockroach Node 组成，每个Cockroach Node 会同时负责SQL执行与数据存储。CockroachDB 底层的存储引擎 RocksDB 会将数据组织成有序的 Key-Value 对形成一个KV map。

### 数据分区

为了支持水平扩展，CockroachDB 会按 KV map 的key的取值范围，在逻辑上水平切分为多个分片，称为 Range。每个 Range 之下会有多个副本（副本数目可配），这些副本会分布在不同的 Cockroach Node 中, 并共同组成了一个 Raft Group,  借助 Raft 协议进行强一致同步，以解决分区级别的高可用与故障容错。Range中被选为 Raft Leader 的 Range 副本 称为 LeaseHolder,  它不但要负责承担来自用户端的写入流量，还要负责 Range 后续的变更与维护（例如，Range 的分裂、合并与迁移）; 而其它非Leader 的 副本则可以承担读流量。为了管理整个系统的元数据，CockroachDB 中有一个特殊 Range, 名为 System Range,  用以保存各个 Table 元数据及其它各个 Range 的物理位置信息。然后，CockroachDB 会基于实际负载情况与资源情况，去调度各个Range 的 LeaseHolder，让它们均衡地散落在各个 Cockroach Node，以达到读写流量能均滩到不同机器节点的效果。

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X水平扩展/1611126563671-6ae18b44-da08-4c36-95ba-8691ab35fbbb.png)

### 水平扩展

CockroachDB 在水平扩展新增加节点时，为了能将一些Range的流量调度到新加入的节点，它会反复多次做两个关键的操作：迁移 Range与分裂 Range。

**迁移 Range**。它可用于解决不同 Cockroach Node 之间负载不均衡。例如，当系统增加了 Cockroach Node，CockroachDB 的均衡调度算法会检测到新增 Cockroach Node 与其它老 Cockroach Node 形成负载不均衡的现象，于是会自动寻找合适的 Range 集合，并通知这批 Range 的 LeaseHolder 自动切换到新增的 Cockroach Node 中。借助 Raft 协议，LeaseHolder 要将自己从 Cockroach Node A 移动到 Cockroach Node B，可以按下述的步骤轻易完成：

-   先往 Raft Group 中增加一个新副本B(它位于 Cockroach Node B )；
-   新副本B 通过回放全量的 Raft Log 来和 Leader 数据一致；
-   新副本B 完成同步后，则更新 Range 元数据，并且删除源副本A（它位于 Cockroach Node A）。

**分裂 Range**。若 Range 数目过少时，数据无法被完全打散的，流量就会被集中少数 Cockroach Node，造成负载不均。因此，CockroachDB 默认了单个 Range 最大允许是64MB（可配置），若空间超过阈值，LeaseHolder 会自动对 Range 进行分裂。前边说过，Cockroach Node 的 Range 划分是逻辑划分， 因此，分裂过程不涉及数据迁移。分裂时，LeaseHolder 会计算一个适当的候选Key作为分裂点，并通过 Raft 协议发起拆分，最后更新Range 元数据即可。
当 Range 经过多次分裂后，产生更多的LeaseHolder，CockroaachDB 的均衡调度算法就可以继续使用迁移 Range 的操作让读写流量分散到其它 Cockroach Node ，从而达到水平扩展且负载均衡的效果。

## PolarDB-X 的水平扩展

PolarDB-X 作为阿里巴巴自主研发的分布式数据库，水平扩展的能力自然是其作为云原生数据库的基本要求。但谈及分布式数据库的扩展能力，通常离不开其架构与分区管理两个方面。接下来，我们通过介绍其架构与分区管理，再来详细说明  PolarDB-X 的水平扩展实现方案。

### 架构

为了最大限度地发挥其云数据库的弹性扩展能力，PolarDB-X 一开始就决定采用了基于存储计算分离的Shared-Nothing架构，以下是 PolarDB-X 的架构图：

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X水平扩展/1611070596517-43936882-fc87-46c0-aa67-c4bce85c08f3.png)

如上图所示，PolarDB-X整个架构核心可分为3个部分：
**GMS(Global Meta Service)**：负责管理分布式下库、表、列、分区等的元数据，以及提供TSO服务；
**CN(Compute Node)**：负责提供分布式的SQL引擎与强一致事务引擎；
**DN(Data Node)**：提供数据存储服务，负责存储数据与副本数据的强一致复制。

PolarDB-X 存储层使用的是 X-DB 。因此，每一个 DN 节点就是一个 X-DB 实例（X-DB的介绍请看这里）。X-DB 是在 MySQL 的基础之上基于 X-Paxos 打造的具备跨可用区跨地域容灾的高可用数据库，使用 InnoDB 存储引擎并完全兼容 MySQL 语法,  它能提供 Schema 级别的多点写 与 Paxos Group 的 Leader 调度的能力 。PolarDB-X 的分区副本的高可用与故障容灾就是建立在X-DB基础上的。

相比其他同样采用 Multi-Group Paxos / Raft 设计的 NewSQL，如 CockroachDB[5]、YugabyteDB[16]等，PolarDB-X  始终坚持与基于 MySQL 原有架构进行一体化的设计的 X-DB 相结合，一方面是考虑到这样能让 PolarDB-X 在MySQL相关的功能、语法以及上下游生态的兼容性与稳定性上更有优势；另一方面是 X-DB 本身具有较强的复杂SQL处理能力（比如Join、OrderBy等），这使得 PolarDB-X 相对方便地通过向 X-DB 下推SQL来实现不同场景的计算下推（比如，Partition-wise Join 等），能大大减少网络开销，提升执行性能，是 PolarDB-X 的一个重要特性。

### 数据分区与表组

#### 数据分区

与 CockroachDB 等分布式数据库类似， PolarDB-X 也会对数据进行切分。在 PolarDB-X 中，每个表(Table)的数据会按指定的分区策略被水平切分为多个数据分片，并称之为分区(Partition)。这些分区会分布在系统的各个DN节点中，而各个分区在DN的物理位置信息则由 GMS 来统一管理。每个分区在 DN节点中会被绑定到一个 Paxos Group,  并基于 Paxos 协议构建数据强一致的多副本来保证分区组的高可用与容灾，以及利用多副本提供备库强一致读。Paxos Group 会通过选举产生分区 Leader， Leader 的分区组负责接收来自CN节点的读写流量；而 Follower 的分区组则负责接收CN节点的只读流量

#### 分区策略

我们知道，分布式数据库常见的分区策略有多种，诸如  Hash / Range / List 等，分布式数据库往往选取其中的一种作为其内部默认的分区方式，以组织与管理数据。像前边提及的  CockroachDB[5] 的默认分区策略是按主键做 Range 分区，YugabyteDB[16] 的默认分区策略则是按主键做一致性 Hash 分区。那么，PolarDB-X 的默认分区策略采用是什么呢？ PolarDB-X 的默认分区也是采用一致性 Hash 分区，之所以这样选择，主要是基于两点的考量：

1.  对一个主键做范围查询的场景在实际情况中并不是很常见，与Range分区相比，一致性 Hash 分区能更有效地将事务写入打散到各个分区，能更好负载均衡；
1.  分布式数据库在进行水平扩展，往往需要添加新的DN节点，采用一致性 Hash分区能做到按需移动数据，而不需要对全部分区数据的Rehash）。

因此，相比于CockroachDB ，PolarDB-X 的默认的一致性Hash分区能更好均摊写入流量到各个分区，这对后边的动态增加DN节点做水平扩展很有意义。
除了默认分区策略，PolarDB-X也支持是用户自己指定分区 Hash / Range / List 等分区策略来管理各分区的数据， 关于 PolarDB-X 分区方式的更多的思考，读者可以参考《谈谈PolarDB-X的分区实现》 这篇文章。

#### 表组与分区组

在PolarDB-X中，为加速SQL的执行效率，优化器针会尝试将分区表之间Join操作优化为Partition-Wise Join来做计算下推。但是，当分区表的拓扑发生变更后，例如，在水平扩展中，分区会经常发生了分裂、合并或迁移后，原本分区方式完全相同的两张分区表，就有可能出现分区方区不一致，这导致这两张表之间的计算下推会出现失效（如下图所示），进而对业务产生直接影响。因此，与CockroachDB相比， PolarDB-X 创造性地通过引入表组与分区组来解决这类问题。

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X水平扩展/1611129259145-ab787009-c633-4237-b844-c2b43906778d.png)

在PolarDB-X中，如果有多个表都采用了相同的分区策略，那么，它们在逻辑上会被PolarDB-X划分为一个组，称之为表组(Table Group)。表组内各个表所对应的相同分区的集合，也会被划分成一个组，叫分区组（Partition Group）。因此，若两张表是属于同一个表组的，PolarDB-X可认为它们采用了完全一致的分区策略，这两张表的各个分区所处的物理位置可以被认为完全相同。这样优化器就会可根据两张表是否属于表组来判断是否做计算下推。

基于上述定义的分区组，PolarDB-X 只要约束所有的分区变更必须要以分区组为单位（即分区组内的各分区，要么同时迁移、要么同时分裂），即可保证在水平扩展的过程中，PolarDB-X 的计算下推不受影响。后文为阐述方便，如无特别说明，所有对分区的操作，默认都是指对分区组的操作。

当引入了表组与分区组后，PolarDB-X还可以额外地满足用户对容灾隔离、资源隔离等场景的需求。因为表组与分区组本质上是定义了一组有强关联关系的表集合及其分区的物理位置信息，所以，同一分区组的分区集合所处的DN节点必然相同。例如， 用户可以采用按用户的ID进行LIST分区建表，然后通过指定分区组的物理位置信息（PolarDB-X支持修改分区组的位置信息），将业务的大客户/重要客户单独的数据划分到更高规格更可靠的DN节点，来实现资源隔离。

### 水平扩展流程

介绍完PolarDB-X的架构与分区策略后，我们开始介绍PolarDB-X的水平扩展。从效果来看，水平扩展的最终目标，可归结为两个：系统没有明显热点，各分区负载均衡；系统的处理能力与所增加的资源（这里的资源主要是DN节点）能呈线性的增长。前边分析的 CockroachDB 的例子， CockroachDB 在做水平扩展过程中，系统的负载均衡其实是通过多次主动的分裂分区或合并，生成多个Range,   然后再通过Leader调度，将各Range的LeaderHolder （负责读写流量的Range） 均衡地散到新加入的CockroachDB节点中来实现。

实事上，CockroachDB 的水平扩展的过程， 放在 PolarDB-X 也是同样适用的。当用户通过 PolarDB-X 默认的一致性Hash预建一些分区后， 它的均衡调度器在内核也会通过多次的分区分裂或合并，来让各分区达到相对均衡的状态（因为即使按默认一致性Hash分区，用户的业务数据本身或访问流量在各分区也可能是不均衡的），达到没有现明显的热点分区。这时，当有新加DN节点加入时，均衡调度器就可以将一部分分区的流量通过分区迁移的方式，将它们切到新DN节点上，从达到扩展的效果。所以，PolarDB-X 的水平扩展，从大体上流程会有以下几个步骤：

1.  加入节点。系统添加一个新的空的DN节点；
1.  分区调度。均衡调度器决定需要迁移到新DN节点的分区；
1.  分区变更。执行**分区迁移**任务(这个过程可能同时还伴随有**分区分裂**或**分区合并**的操作)；
1.  流量切换。被迁移的分区的流量切换到新DN节点，达到负载均衡状态。

整个过程的实现要依赖到的分区变更操作有3种：分区迁移、分区分裂与分区合并，这一点与 CockroachDB 类似。分区迁移主要用于解决不同DN节点之间负载不均衡的问题，而分区的分裂与合并则可用于解决不同分区之间的负载不均的问题以及因分区数目不足水平扩展受限的问题。下边我们继续关注 PolarDB-X 这3种分区变更操是如何实现。

### 基于 Online DDL 的分区迁移

分区迁移通常需要两个步骤分区复制与流量切换两个阶段。像 CockroachDB 基于 Raft 协议来完成跨节点间的数据复制以及 Leader切换(流量切换)，所以它的分区迁移能几乎全被封装Raft协议里进行。但是，PolarDB-X 跨DN节点之间的分区复制，并没有基于  Raft/Paxos 协议 ，而是参考 SAP HANA 提出的非对称分区复制[2] 的思路，采用了 Online DDL [1]  的方案。

更具体来说，就是 PolarDB-X 会将分区副本的数据复制操作，看作是一次给主表（源端DN节点）添加一个特殊索引（目标端DN节点）的DDL操作，这个特殊索引会冗余主表所有的列。所以，整个分区复制的过程就等价于基于 Online DDL 添加一次索引。类似地，PolarDB-X的流量切换没有借助走 Raft/Paxos 协议的切主来进行切流，而是采用基于 Online DDL 删除索引的方式来完成流量从源端（老DN节点）到目标端（新DN节点）的对应用近乎透明的平滑切换，这个过程在PolarDB-X中被称为透明切换。

如下图所示，组成 PolarDB-X 分区迁移的 **分区复制**与 **透明切换** 两个关键阶段。

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X水平扩展/1611151700525-543811e5-1c56-4df7-8137-59712b4e419b.png)

下边将会详细介绍PolarDB-X  是如何基于 Online DDL 来实现分区复制与透明切换，以及最终达对用户透明的效果。这里边会涉及 Google F1 论文《Online, Asynchronous Schema Change in F1》一些细节，建议读者可以先读下PolarDB-X 的篇文章《PolarDB-X Online Schema Change》了解 Online Schema Change中原理。

#### 分区复制

**分区复制**的任务是要在目标DN节点上构建一个新的分区副本。借助 Online Schema Change，该阶段会对目标分区进行一次添加“索引表”的操作，完成后该 “索引表” 便成为新的分区副本。所以，分区复制的DDL任务状态与添加索引的类似, 分为 Absent、DeleteOnly、WriteOnly、 WriteReorg 与 ReadyPublic 5个状态（如下图所示）。

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X水平扩展/1611151835098-f9b059df-ccee-4fd3-9e36-cbd6a187cadd.png)

前三个状态 Absent、DeleteOnly、WriteOnly 的定义与添加索引的完全一致，新引入的两个状态 Write Reorg 与 Ready Public 的定义如下：

-   **WriteReorg**。处于该状态的节点的行为与 Write Only 完全一致，即要负责维护主表（即原分区）所有的增量数据及其索引表（即新分区副本）数据的一致性。可是，当节点处于该状态时，说明 GMS 正在执行数据回填（BackFill）任务来为主表的存量数据补充其索引数据。
-   **ReadyPublic** 。处于该状态的节点的行为与 Write Only 也完全一致。可是，当节点处于该状态时，说明 GMS 的 BackFill 任务与相关的数据校验工作已经完成，此时节点会认为当前主表与索引表的数据已完全一致，可随时进入下一阶。

分区复制的DDL任务状态新引入上述两个状态，目的有两个：（1）数据回填任务通常运行时间比较长（从几分钟到几小时不等），通过将数据回填任务单独抽象为 WriteReorg 状态，可方便CN节点的SQL引擎能针对该状态下的DML的执行计划做一些优化工作；（2）当完成数据回填任务后，目标分区其实并不需要真的像索引表那样要对外开放检索，而是需要马上进入下一阶段，因此，需要 ReadyPublic （与Public区分）这个状态来让节点知道当前主表与索引表的数据已经完全一致，达到进入下一阶段的要求。

#### 透明切换

**透明切换**的任务是要将原分区的读写流量全部切换到新的分区副本，并且要全程对应用保持透明。所谓保持透明，就是在整个切换过程中，不能产生让应用感知的报错，不能让应用的读写流量受影响，不能让数据产生不一致。那常见的流量切换方案，例如，直接切流、停写后再切流等方案，是否能满足“透明”的要求呢？我们可分情况讨论。

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X水平扩展/1611154782272-76591f39-b78b-454c-ae7f-2a6112d411d6.png)

如果采用直接切流的方案（上图左侧），那切换期间分布式系统中便会因为节点状态不兼容（因为所有节点不可能在同一时间完成切换）而导致出现数据不一致；如果采用停写后再切流的方案（上图右侧），那需要通知分布式系统所有节点来阻塞业务所有的写操作，但通知过程本身时间不可控（或网络故障或节点自身不可用），应用有可能导致被长时间阻塞写，从而使应用侧会产生超时异常。可见，无论是直接切流还是停写后再切流的方案，都不能满足保持透明的要求。

PolarDB-X为了实现透明的切换效果，其思路是将目标端分区看作是主表，将源端分区看作是索引表，并对主表进行一次标准的删除索引的 Online DDL 操作(其状态过程是 Public-->WriteOnly-->DeleteOnly-->Absent ，与 Online Schema Change 定义的一致)。

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X水平扩展/1611156194155-039aa107-858c-4d82-906c-4ab7e0a1d8d4.png)

如上图所示，在  Online DDL 期间，由于新索引表会被逐渐下线，CN节点的SQL引擎根据不同DDL状态，将不同类型的流量分步骤地从源端（索引表）切换到目标端（主表）：先切Select流量（WriteOnly状态，索引表不可读），再切Insert流量（DeleteOnly状态，索引表不可插入增量）, 最后才切Update/Delete/加锁操作等流量（Absent状态，索引表不再接收写入）。基于 Online DDL ，整个切换会有以下几点的优势：

-   切期期间业务读写不会因被阻塞(不需要禁写)；
-   切换期间不会产生死锁（因为在WriteOnly与DeleteOnly状态的节点，加锁顺序都是一致）；
-   切换期间不会产生数据不一致的异常（Online Schema Change 论文已证明）。

这些优势使得流量切换全程能对应用做到了透明。

#### 多表并行与流控

前边说过，为了保持计算下推，PolarDB-X 的分区迁移其实是以分区组为来单位进行。一个分区组通常会有多个不同表的分区，所以，分区迁移过程产生的数据回填任务，通常是将分区组内的多个分区进行并行回填，以加速迁移的速度。

回填任务是一个比较消耗时间与消耗资源的后台操作，涉及源端到目标端的大量数据复制，如果其速率太快，容易过多地占用DN节点的 CPU 与 IO 资源，对业务的正常读写造成影响；如果其速率太慢，分区迁移过程的运行时间又可能会太长。因此，在Online DDL 的框架下，数据回填任务会支持进行动态流控：一方面允许按人工介入来调整任务的状态（例如暂时任务），另一方面可以根据节点的资源情况来动态调整数据回填速率，以避免对业务产生过多影响或迁移过程太慢的问题；

透过数据回填的流控例子，PolarDB-X  基于 Online DDL 的分区迁移方案，相比于 CockroachDB 等基于 Raft 协议做一致性复制的方案，虽然增加了一定的实现复杂度，但却可以带了更灵活的对用户更友好的可控性。

### 基于  Online DDL 的分区分裂

PolarDB-X 分区 与 CockroachDB 分区 的存储方式有一定的差异：同一 Cockroach Node 中不同 Range 只是逻辑上的划分，物理存储是共用一棵 RocksDB 的 LSM-Tree； 而 PolarDB-X 中同一DB节点的不同分区实际上是对应着的是 X-DB 中的不同的表（即MySQL中的一张表），每张表都是一棵 B+Tree，它们之间的物理存储是分开的。因此，PolarDB-X 的 分区分裂本质上是将 InnoDB 的 B+Tree 由一棵拆分为两棵的过程，这个这程中间必然需要涉及到数据的复制与重分布。诸如 CockroachDB 仅通过修改 Range 元数据来完成分区分裂的做法，对于 PolarDB-X 的分裂操作将不适用。考虑到分裂过程中数据复制与重分布，PolarDB-X 的分区分裂同样是采用 Online DDL 的实现方式。套用 Online DDL 的框架，PolarDB-X 的分区分裂其实可看成是对分区迁移的一种扩展。回顾分区迁移的运行过程：

-   首选，将源端分区看作主表，将目标端分区看作是主表的索引表，并通过一个添加索引的 Online DDL 操作实现从源端分区到目标端分区的数据复制；
-   然后，重新将目标端分区看作是主表，将源端分区看作是索引表，再通过一个删除索引的 Online DDL 操作实现读写流量从源端分区切换到目标端分区。

在这过程中，源端分区与目标端分区一直被当作独立主表与索引表来处理，主表与索引表本身的分区方式是否相同，不会对整个模型的运作产生影响。因此，在分裂场景中，若将分裂后的两个新分区看作一个分区索引表（即该索引表有两个分区），而该分区索引表依然可以看作是源端分区的一个副本。这样，分区分裂便可以继续套用分区迁移的全部流程，其中需要扩展的地方就是所有产生对分区索引的Insert/Update/Delete操作都要要再经过一次分区路由（Sharding）以确定要修改真实分区。于是，基于这个思路，分区分裂就可分下几个阶段来完成：

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/PolarDB-X水平扩展/1610949296412-1496ae67-2b1a-4fca-b4aa-f65aa66260eb.png)

-   **准备分裂后的分区**。在此阶段，PolarDB-X GMS 找两个空闲的DN节点, 根据分裂点（Split Point）将原分区的取值空间划分成两个部分，并在空闲的DN节点上构建这两个新的空分区；
-   **带分裂的分区复制**。该阶段与分区迁移的分区复制类似，不同的是所有源于主表修改而产生的对分区索引表的修改都需要先经过一次分区路由，以确定其实际的修改位置（如上图所示）。
-   **带分裂的透明切换**。该阶段与分区迁移的透明切换类似，不同的是所有切到分区索引表的读写流量都要先经过一次分区路由，以确定其实际的修改位置（如下图所示）。
-   **数据清理**。该阶段与分区迁移数据清理类似，需要将被分裂的分区数据进行清理以及相关元数据的刷新。

PolarDB-X 的分区分裂由于基本复用了分区迁移的流程。因此，分裂过程也是以分区组为单位进行，分裂前后不会PolarDB-X  的计算下推不会受影响。

## 总结与展望

基于 Share-Nothing 架构的 PolarDB-X 通过对数据进行水平分区，解决了单机数据库写能力无法水平扩展的问题。每个分区基于 Paxos 协议实现多副本的强一致复制，并支持分区级的高可用、错误容灾与利用多副本提供读扩展的能力。PolarDB-X  支持通过动态增加数据节点实现存储层的水平扩展与自动负载均衡。但是，为了避免水平扩展过程中的负载不均衡，引入了分区迁移与分区分裂两项必须的基本能力。

分区迁移能解决数据节点之间的负载不均衡的问题。可进行分区迁移之前必须先做分区复制，但以 X-DB 作为存储的PolarDB-X，暂时无法借助 Paxos/Raft 协议实现跨机（跨数据节点）的分区复制与分区流量切换。因此，PolarDB-X 通过复用基于 Online DDL 的添加索引的过程来完成对应用透明的跨机分区复制。更进一步，PolarDB-X 还将  Online DDL 的机制推广到跨机分区迁移，将通过复用删除索引的 Online DDL 过程来解决了分区迁移过程读写流量从源端到目标端的切换问题。PolarDB-X 基于 Online DDL 的分区迁移可以做到全程对应用无感知，迁移过程的回填任务支持流控，避免资源占用过多并对应用产生影响。

分区分裂能解决分区之间的负载不均衡的问题。可是 PolarDB-X  的每一个分区对应一张物理表，分裂过程要将一张表拆分多张表，因此，该过程需要涉及到对分区的数据复制与重分布。鉴于要涉及分区的数据复制，PolarDB-X 的分区分裂同样是采用 Online DDL 的实现方式，其思路是通过扩展分区迁移的模型：分区迁移是通过复用添加索引的DDL过程完成分区复制，而分区分裂则是将添加索引的操作扩展为添加分区索引，以解决分裂过程中涉及的数据重分布问题。

通过分区分裂，PolarDB-X 能产生更多分布在不同数据节点的分区；通过分区迁移，PolarDB-X能均衡不同数据节点间之间负载，如此往复，最后达到水平扩展的效果。

与诸如 CockrocachDB等主流的NewSQL数据库相比，PolarDB-X 的水平扩展方案带有与自己架构紧密相关的特色，以下是 PolarDB-X 水平扩展与其它 NewSQL 数据库 的对比。

<table>
<tr class="header">
<th>维度</th>
<th>CockrocachDB</th>
<th>YugabyteDB</th>
<th>PolarDB-X</th>
</tr>
<tr class="odd">
<td>SQL兼容性</td>
<td>PostgresSQL</td>
<td>PostgresSQL</td>
<td>MySQL</td>
</tr>
<tr class="even">
<td>分区存储引擎</td>
<td>RocksDB</td>
<td>RocksDB</td>
<td>InnoDB</td>
</tr>
<tr class="odd">
<td>分区副本高可用</td>
<td>Raft</td>
<td>Raft</td>
<td>Paxos</td>
</tr>
<tr class="even">
<td>分区跨机迁移</td>
<td>Raft</td>
<td>Raft</td>
<td>Online DDL</td>
</tr>
<tr class="odd">
<td>水平读扩展</td>
<td>支持</td>
<td>支持</td>
<td>支持</td>
</tr>
<tr class="even">
<td>水平写扩展</td>
<td>支持</td>
<td>支持</td>
<td>支持</td>
</tr>
<tr class="odd">
<td>水平扩展期间保持计算下推</td>
<td>不支持</td>
<td>不支持</td>
<td>支持</td>
</tr>
<tr class="even">
<td>水平扩展期间的应用影响</td>
<td>不影响</td>
<td>不影响</td>
<td>不影响</td>
</tr>
<tr class="odd">
<td>水平扩展期间的流控</td>
<td>不支持</td>
<td>不支持</td>
<td>支持</td>
</tr>
<tr class="even">
<td>水平扩展期间的效率</td>
<td>优秀</td>
<td>优秀</td>
<td>良好</td>
</tr>
</table>

## 后记

分布式数据库中，水平扩展通常与分区管理、负载均衡方面紧密结合。本文限于篇幅，暂时只对PolarDB-X 水平扩展方面作了一些原理性的介绍，像动态分区管理、自动负载均衡（如分区物理位置的选择、分裂点的选择、如何分区做迁移等）的一些细节没涉及太多说明，请读者关注后续的文章。

## 参考文献

-   [1] [Online, Asynchronous Schema Change in F1]().
-   [2] [Asymmetric-Partition Replication for Highly Scalable Distributed Transaction Processing in Practice]().
-   [3] [Elastic Scale-out for Partition-Based Database Systems]().
-   [4] [TiDB: A Raft-based HTAP Database]().
-   [5] [CockroachDB: The Resilient Geo-Distributed SQL Database]().
-   [8] [In Search of an Understandable Consensus Algorithm]().
-   [9] [What’s Really New with NewSQL]().
-   [10] [Spanner: Google's Global-Distributed Database]().
-   [12] [Comparison of Different Repliacation Solutions](https://www.postgresql.org/docs/12/different-replication-solutions.html).
-   [13] [MySQL Group Replication](https://dev.mysql.com/doc/refman/8.0/en/group-replication.html).
-   [14] [Paxos Made Simple]()
-   [15] [In Search of an Understandable Consensus Algorithm]()
-   [16] [YugabyteDB: Automatic Re-sharding of Data with Tablet Splitting](https://github.com/yugabyte/yugabyte-db/blob/master/architecture/design/docdb-automatic-tablet-splitting.md)
-   [17] [MySQL:Replication for Scale-Out](https://dev.mysql.com/doc/refman/8.0/en/replication-solutions-scaleout.html)



Reference:

