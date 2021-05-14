## 概述

PolarDB-X是一款基于MySQL的分布式数据库，在MySQL的单机事务基础上，实现了全局一致分布式事务。之所以基于MySQL实现分布式事务，很重要的一个原因在于实现一个工业级的存储引擎需要非常多的工程投入和场景打磨，非一日之功。而MySQL的存储引擎在业界来说相对成熟，在阿里双十一这样的场景下承担了核心存储的角色。

因此，本文主要分析MySQL/InnoDB的事务实现，讲述一个高性能的存储引擎的理论及工程实现，为后续PolarDB-X的高性能分布式事务留下铺垫。

## 基本原理

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616898059111-224e728f-e06f-409a-b2d0-c89dfe4016df.png)

在 MySQL/InnoDB 中，使用MVCC(Multi Version Concurrency Control) 来实现事务。每个事务修改数据之后，会创建一个新的版本，用事务id作为版本号；一行数据的多个版本会通过指针连接起来，通过指针即可遍历所有版本。

当事务读取数据时，会根据隔离级别选择合适的版本。例如对于 Read Committed 隔离级别来说，每条SQL都会读取最新的已提交版本；而对于Repeatable Read来说，会在事务开始时选择已提交的最新版本，后续的每条SQL都会读取同一个版本的数据。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616898378214-a6f46efe-0014-45ba-9ffe-1b8ba7b6fbbb.png)

在事务提交之前，需要检查事务之间的冲突，以满足隔离级别的需求。例如，两个事务分别执行了 `x = x + 1` ，它们都读了同一个版本的变量 x，且都想更新成同一个值，如果它们都提交了，显然破坏了事务隔离，因为其中一个事务的更新丢失了（Lost Update)。在 InnoDB 中，在更新数据时会对其进行加锁实现事务的互斥，解决冲突，例如这里的update，会在读之前即加锁，另一个事务则无法更新同一行数据了。除此之外，也有其他的冲突检测方法，这里我们将其统称为并发控制算法。

在MVCC的基础上，还需要考虑版本的回收问题，即删除无用的版本。何时版本能够回收？简单来说，当一个版本对所有活跃事务都不可见了，即可回收，因此通常还需要维护活跃事务的所有快照，根据其中最旧的快照来确定可回收的版本。

---

## 设计空间

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616729678890-ca42ffda-ef5c-4458-977a-6390c8080090.png)

以上的基本原理很简单，但要实现一个高性能的事务引擎，还需要Deep Dive下去考虑更多细节问题。因此这里对事务引擎的设计空间简单分析一下。

我们这里借鉴《An Empirical Evaluation of In-Memory Multi-Version Concurrency Control》这篇文章中的提法，对事务引擎分成几个角度进行讨论：

-   并发控制协议：如何检测事务之间的冲突，满足隔离性需求？
-   多版本存储：多版本数据如何存储，如何回溯旧版本数据？
-   垃圾回收：旧版本的数据如何回收？
-   索引管理：索引如何指向多版本数据？

#### 多版本存储

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616899015011-d90d5639-b9d7-43a4-9dcd-a77e00598216.png)

常见的多版本存储有几种方案，Old To New、New to Old, Delta等。

例如Postgres使用了Old To New的存储策略，一行数据的所有版本都存储在Heap中，并用指针链接起来。在进行版本遍历时，根据指针加载相应的Page并读取数据。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616899253787-9e0f94fb-97b1-4398-8f2c-3b03d2a3643d.png)

这种方案的优势在于，一行数据的多个版本往往具有局部性，可以存放于同一个Page中，读取时不需要增加额外的加载Page的开销。但其劣势在于，当版本链不断增长时，读取最新版本的开销就会不断增大；且由于多个版本都存放于Heap中，会带来一定程度的空间浪费，以及相应的缓存浪费。

另一种与之相反的方案是New To Old, 即主表存最新的版本，用链表指向旧的版本。当读取最新版本数据时，由于索引直接指向了最新版本，因此较低；与之相反，读取旧版本的数据代价会随之增加，需要沿着链表遍历。

在N2O的方案中，通常会把旧版本的数据存储于独立的物理空间，例如Rollback Segment，便于历史数据的清理。这样的优势在于可以减少O2N方案中的空间放大问题；但劣势在于，访问旧版本数据的代价较高，因为旧版本数据的分布相对分散，不具有局部性。

O2N和N2O是两种基础的方案，在此基础上可以进一步优化。例如仅仅存储Delta而非全量数据，可以进一步减少存储空间。

#### 索引管理

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616900500412-dec0a9ae-7b20-4bc2-8999-e83203e70550.png)

采用O2N或者N2O的方案，不仅影响到主表的数据访问，还对索引的设计产生影响。

如果采用了N2O的方案，则通常意味着每次更新了主表数据之后，都需要修改相应的索引，指向新的数据。当然，此时可以采用Logical Pointer的方式，让索引指向一个Rowid 或者 Primary Key，使得在Index Key不发生修改的时候不需要更新索引。

在O2N的方案中，由于索引指向了旧版本的tuple，因此不需要在更新主表数据时同时修改索引。但这同时会带来一个问题，当主表的旧版本数据进行垃圾回收时，如果直接删除旧版本数据，那么势必要更新索引指向的地址，就会造成较大的索引更新的开销。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616900671933-825eaa35-9904-4a57-a9f3-add0b303c5c4.png)

针对这一问题，Postgres采用了HOT的方案进行优化。当需要删除旧版本Tuple时，Page中的Tuple会随之删除，但索引指向的第一个的Item Pointer不会删除，而是指向新版本的Item Pointer，这样通过一次跳转即可访问到新版本的数据。

#### 并发控制算法

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616737075244-7f0f6373-e437-432d-8e45-f37a27b32002.png)

并发控制算法的讨论空间较大，不论是学术界或者工业界都对这个问题有过很多研究。这里只简单讲一下几种朴素的算法，实际上多种算法之间可以进行Hybrid，这种时候我们就不必过多纠结其名字了。

在Timestamp Ordering算法中，每个Tuple会维护三个状态，read-ts、begin-ts、end-ts。begin-ts即写入这个tuple的txid，end-ts则是删除这个tuple的txid，其中一个特别的状态是 read-ts，当事务成功读了一个tuple之后，需要将其read-ts设置为其txid，随之后续的事务无法更新这个tuple，除非txid大于read-ts。

在Optimistic Concurrency Control中，事务采用乐观的方式执行，即执行过程中不需要对修改的数据加锁，从而避免了加锁的开销。OCC的方案分为三个基本流程，Read、Validate、Write，Validate过程中需要检测其ReadSet是否被其他事务更新过，如果检测通过，则在Write阶段写入新版本。

在Two-Phase Locking中，事务需要在执行过程中加读写锁，这个锁通常不需要额外的锁表，而是通过tuple上的read-cnt 和 txn-id 充当锁的作用。这里所谓的Two-Phase，即Grow Phase 和 Release Phase，即任何锁释放之后，都不可以再进行加锁。

以上只是几种基本的并发控制算法，实际工程中可以对其进行弱化和组合，得到更多的并发控制算法。在工业界，通常采用的Snapshot Isolation、SSI、MVTO等算法，也是在这些基础算法上进行修改和适配。

#### 垃圾回收

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616737274867-abadd8fd-af47-415c-a1f7-5f864fdbe95b.png)

至于垃圾回收的问题，其目的在于删除无用的版本，释放存储空间，避免执行开销。

常见的方法是Tuple-Level，前台线程/后台线程在遍历版本数据时检查版本是否可见，如果不可见即可回收。这种方法的局限性在于，回收的代价较大，需要扫描大量数据。如果回收不及时通常也会造成性能瓶颈。

另一种方式是 Transaction Level , 事务记录自己的 Writeset，当事务结束之后针对Writeset来清理。

垃圾回收在工程上是一个很重要的问题，类比于JVM GC，当它正常工作时你可能察觉不到，但一旦出问题了，可能就会导致Stop The World，Out Of Memory等问题。而在存储引擎中，如何垃圾回收不及时，可能就会导致存储空间的膨胀，或者事务执行速度下降。

在学术界近几年也有一些针对垃圾回收的工作，主要集中在HTAP的场景下，如何避免长AP事务影响垃圾回收。

#### 小结

从以上的讨论来看，事务引擎发展了这么多年，目前仍然是一个没有标准答案的问题，通常还是需要针对不同的场景设计不同的数据结构和算法，进行针对性的优化。并且事务引擎的主要优化目标在于性能，进行性能优化时往往容易发生优化一个场景却劣化了另一个场景的问题，这样的例子即便在成熟的工业级存储引擎也屡见不鲜。

---

## 工程实现

以上仅仅是理论，接下来讨论InnoDB的工程实现问题。

#### 多版本存储

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616903606043-beeeb870-191b-497a-8597-a8945d014acf.png)
InnoDB的多版本存储采用N2O的方式，主表数据存储于聚簇索引中，用指针指向旧版本的数据；旧版本的数据存储于undo log中。这里的undo log起到了几个目的，一个是事务的回滚，事务回滚时从undo log可以恢复出原先的数据，另一个目的是实现MVCC，对于旧的事务可以从undo 读取旧版本数据。

在Tuple的格式中，除了实际的payload 之外，还有额外的 TRX_ID 和ROLL_PTR字段，其中 TRX_ID 是创建这个Tuple 的 TRX_ID，而 ROLL_PTR 则是指向了undo 的指针。

当事务修改数据时，需要根据操作类型的不同，写入不同的undo log。主要分为INSERT和MODIFY两种，对于INSERT来说，把新写入的数据写到undo log；而对于update，则是把旧版本的数据拷贝到undo log。同时会把undo 的地址返回作为rollback pointer，记录到主表数据的tuple中。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616904091353-fc0135e0-4705-4c97-b321-1f24efb070fa.png)

undo本身的存储空间管理如上所示，这里不再赘述。

#### 快照可见性

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616907323424-c4c27bf7-c10c-4a74-88e3-a08e06285019.png)

并发控制的关键在于事务可见性判断，以上图为例，当 Tx5 开始时，需要对所有事务打一个快照，确定哪些事务可见，哪些事务不可见。这里用事务的可见性关系来表示出数据的可见性关系，是因为每行数据都会关联上事务id，相对来说事务id 会是一个更加紧凑的表示方法。

具体到快照，对于Tx5来说，它所看见的快照是这样的：Tx1 已提交，Tx2, Tx3, Tx4 正在运行，而 Tx5 是还未开始的事务。因此，根据这个信息可以做出如下的推断：对于 `trxid < tx1` 的事务写的数据，属于已提交数据一定可见；对于 tx2, tx3, tx4 的事务写的数据，不可见，因为事务此时还未提交；对于tx5 之后的事务写的数据，一定不可见，因为事务此时还未开始。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616907813803-ee1a77b0-efe0-4bce-a396-bf123f6451f7.png)

这样的快照可以表示成 `tx1, tx5, [tx2,tx3,tx4]` ，基于这个快照，便可以对每一个tuple判断可见性了。

#### 事务状态

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616905761261-74d10c21-f9cd-49df-8d6c-9f2d64617d94.png)

为了实现以上的快照，需要维护以下几个状态：

-   事务状态 `trx_t`
    -   对于单个事务来说，有id、state、read_view、lock等状态

-   全局事务：
    -   `rw_trx_list` ，维护了所有的活跃事务
    -   `rw_trx_ids` ，记录所有活跃事务id
    -   `rw_trx_set` ，从trxid 到trx_t的映射
    -   `max_trx_id` ，分配单调递增的 `trx_id`

-   快照列表 `MVCC`
    -   `views` : 所有的ReadView

-   ReadView：
    -   `low_limit_id` , `up_limit_id` , `ids` ，维护了快照状态

其中的ReadView即上述的快照，其中的 `low_limit_id` , `up_limit_id` , `ids` ，分别应和了前面举例的已提交事务，活跃事务列表，未分配事务。除此之外还需要记录使用这个ReadView的事务id，保证自己写的数据对自己可见。

系统中每个事务都会至少持有一个ReadView，对于Repeatable Read的事务来说是整个事务分配一个ReadView，而对于Read Commit事务来说每条SQL使用一个ReadView。系统中的所有ReadView则通过链表进行管理，即 `MVCC` 数据结构中的 `views` 链表。

在创建ReadView时，需要对全局活跃事务链表进行加锁，计算当前的活跃事务。这里的全局活跃事务在 `trx_sys_t` 中维护，并通过一个全局的mutex进行保护。其中 `rw_trx_ids` 维护了当前的所有活跃事务，创建 ReadView 时拷贝这个数据结构即可。

这里带来一个问题，在高并发的场景下，创建ReadView会是一个非常频繁的操作，例如想跑到几十万的QPS，意味着每秒就需要创建几十万个ReadView，如果都通过一个Mutex，那么势必会成为瓶颈。因此在MySQL 5.7引入一个ReadView Cache机制，如果两个ReadView创建之间，没有任何RW事务提交，那么其实这两个ReadView的快照其实是一样的，这意味着就不需要重复创建ReadView了，而是可以重用之前的。按照这个机制，当一个AUTO-COMMIT READ-ONLY的ReadView释放之后，并不是立即删除，而是放回链表中，当下次取出时，判断其 `m_low_limit_id` 是否和当前的 `max_trx_id` 相同，如果相同，即可重用这个 ReadView而无需重新创建。

#### Purge

Purge即垃圾回收，其目的在于释放无用的数据版本，从而回收存储空间。

基于以上的ReadView状态，进行purge时首先需要找到当前最旧的ReadView。由于系统中的所有ReadView都用链表进行连接，并且其顺序就是创建顺序，因此链表中最后一个ReadView其实就是 `oldest_read_view` ，但考虑上述的ReadView Cache机制，还需要排除 `closed` 状态的ReadView。

根据 `oldest_read_view` , `>=` 的数据会保留，而 `<` 的数据则可以物理删除。为了提高purge本身的效率，避免遍历所有 rollback segment， `purge_sys` 用优先队列维护了待 purge 的rollback segment，根据 `trx_no` 排序，从最早提交的事务开始进行回收。

#### 小结

以上总结了InnoDB的多版本存储、快照、事务并发控制等方面的实现原理，除此之外还有一个重要的问题在锁的实现，这部分较为复杂，在后续的文章会有讨论。

> 在讨论到垃圾回收的问题时，常见的做法是计算最旧的事务快照，回收之前的数据。但这种方案的局限性在于，当存在一个长事务的情况下则会阻碍垃圾回收，发生数据膨胀。那么读者可以想象一下，版本链之间的数据有没有可能回收呢？


---

## 高可用事务

以上讨论的是单机事务引擎的实现，接下来讨论的是高可用的事务如何实现。

#### RSM模型

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616739733954-28e0c726-951b-4631-85b8-109a0a1c05c4.png)

在较早的混乱时期，数据库采用了各种同步复制、异步复制、半同步复制等各种模型，但这些方案都有或多或少的问题，要么不能保证数据一致性，要么在异常情况下做不到高可用。

到2021年，基本已经统一到 RSM 模型 加上 Consensus 协议，因此我们主要来讨论一下这种方案。

在RSM模型中，命令通常采用 Submit、Commit、Apply的流程执行，即客户端提交命令到一致性模块、一致性协议对命令写日志并进行复制、当日志复制到Majority节点之后认为判定Commit、Commit的命令提交给状态机进行Apply。

#### 数据库的复制模型

以上的RSM在数据库里实现会稍有区别，并不是简单地把binlog加上一个raft，而是采用 Speculative 的方案。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616855311503-3796d229-a3af-4dd3-80cb-6271f2a73d9a.png)

在数据库中，复制的基本粒度是事务，事务的顺序通过并发控制算法来决定，例如常见的2PL、Snapshot Isolation、Optimistic等都可以确定事务的执行顺序。这里所谓的顺序在数据库的范畴内通常称之为 Serialization Order，即不违背冲突的情况下与之等价的执行顺序。在通过并发控制算法确定了执行顺序之后，事务会进入提交阶段，并写WAL来实现故障恢复。

为了实现高可用，通常会在事务提交过程中插入一个日志复制的流程来实现高可用。简单来说，事务会先进行XA Prepare，并通过redo log进行持久化；接着写 binlog，并复制到其他节点；最后事务进行提交，再次写 redo log。这里的XA是为了保证 redo log和 binlog的一致性，在故障恢复时先通过 redo log 恢复出 prepared & uncommitted事务，再检查 binlog是否需要commit这个事务。

#### x-paxos

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616740465314-badae5f1-3461-472b-8da8-6041df8bdbee.png)

以上的模型虽然看起来简单，但确是困扰MySQL许多年的问题，例如以上的事务提交流程是否只能串行？如何减少IO？如何尽量提高性能？

在PolarDB-X中，采用了x-paxos作为复制协议，并基于MySQL binlog实现高可用，通过大量的工程优化实现了高性能。

基于binlog group-commit的基本框架，x-paxos实现了以下的事务提交流程：

-   Flush：刷binlog cache，写事务prepare
-   Sync：等待 binlog 刷盘，并通知Consensus Module进行复制，并等待 binlog 复制到Majority
-   Commit：当binlog commit之后，进行事务的提交

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1616896942209-190a568e-db85-4cde-8900-508af5a6d0c4.png)

这三个阶段通过流水线执行的方式来实现并行，并实现了Group的效果：

-   事务进入到一个Stage之后把自己添加到相应的Queue中，并发的事务则会同时进入同一个queue，通常会落在同一个Group内执行
-   如果事务是Queue的第一个事务，则承担Leader的角色，即把Queue中的事务取出来，作为同一个Group执行，而Follower只需要等待Leader完成任务
-   这里Group的目的一方面在于完成IO的合并，将多个小的IO合并成一次刷盘操作，另一方面也为了减少锁的竞争
-   Leader完成一个Stage之后，会先把事务放到下一个Stage的Queue中，再释放当前Stage的Mutex，这个顺序是为了避免上一个Stage的事务抢先进入下一个Stage，破坏事务的提交顺序

基于这样的流水线并行，可以保证每个事务按照串行顺序执行，同时多个Stage之间又可以并行执行，且IO等操作可以得到合并从而减少开销。

当然，目前的group-commit并非完美，事务的提交开销仍然较大，需要进行多次刷盘，引入较大的开销。PolarDB团队针对这一问题也做了一些改进工作，进一步提高事务提交的性能，后续的文章会进一步介绍。

#### 并行回放

按照以上的方案在Leader节点可以实现比较好的并发性能，那么接下来需要考虑的一个问题就是如何在Follower节点保证同样的性能，避免出现数据落后。

对于Follower节点来说，需要明确的一个问题在于，按照何种顺序去回放binlog，才能保证正确性？

MySQL对这个问题的思考进行了几个阶段：

-   ~5.6：库级并行，表级并行
-   5.6 Group Commit：在binlog group-commit过程中给group内的事务打上标记，从而在Follower上并行回放
-   8.0 Write Set：实现真正的行级并行，基于row hash判定事务冲突

第一个表级并行的方案，正确性容易理解，基本是按照binlog的顺序去回放日志，但其性能瓶颈也相对明显。第二个基于Group Commit的方案中，其正确性的前提在于一个group内的事务没有并发冲突，因此即便并行也不会破坏事务的执行顺序。这个方案的局限性在于一个group 内的并行度仍然有限，如果Leader节点的并发度较低，那么group则相对较小，从而限制了Follower回放的并发度。第三个基于Write Set的方案，则进一步将并行的粒度缩小到行级，每一行的回放仍然串行，但行与行之间则完全并行。

#### 小结

以上的讨论中，binlog的复制需要穿插在事务提交流程中，这往往会影响事务提交的效率，那么，有没有可能仅仅在事务提交流程中对binlog复制进行定序，而将实际的binlog复制挪到事务提交流程之外呢？这个问题我们后续会进行讨论。

## 分布式事务

![undefined](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/InnoDB事务_从原理到实现/1617342272813-7a7664f9-8518-4305-b05f-b5b4f75d8d29.png)

以上是对单机事务的原理和工程的分析，在单机事务的基础上，分布式事务也是一个热点的问题。

在分布式的场景下，如何保证事务的原子性提交？传统的两阶段提交的方案虽然简单，但是通常会引入额外的多次网络RT和IO延迟，性能堪忧；而Deterministic的事务虽然不需要走2PC，但是对交互式的支持又捉襟见肘。

又例如，如何保证事务的快照一致性？工业界常采用的Global Transaction Manager的方案会在GTM节点维护全局活跃事务，这很容易成为系统瓶颈，OCC方案常采用中心化的提交状态管理，也存在较大的事务提交开销。

除此之外，如何实现分布式并发控制，如何把单机的2PL、SI、OCC、TO等方法推广到分布式的场景下，并且避免中心化的瓶颈？

PolarDB-X对分布式事务这个问题有过很多的思考，在我们之前的文章有过一些讨论，感兴趣的读者可以参考这些文章：

-   [PolarDB-X 分布式事务的实现（一）](https://zhuanlan.zhihu.com/p/338535541)
-   [PolarDB-X 分布式事务的实现（二）InnoDB CTS 扩展](https://zhuanlan.zhihu.com/p/355413022)
-   [PolarDB-X 强一致分布式事务原理](https://zhuanlan.zhihu.com/p/329978215)
-   [PolarDB-X全局时间戳服务的设计](https://zhuanlan.zhihu.com/p/360160666)

## 总结

本文概述了InnoDB的事务实现原理，从理论的设计空间，到具体的工程实现，以及在单机事务的基础上实现高可用事务。篇幅虽长，但仍然只覆盖了事务处理技术的冰山一角，无法覆盖到这个技术方向上几十年的演进。

在PolarDB-X中，基于业界广泛采用的InnoDB，在保证稳定可靠的基础上，做了大量的工程优化，实现了高性能的分布式事务。其他文章已经对PolarDB-X的分布式事务技术进行了详细介绍，这里不再赘述。

除此之外，不论是单机存储引擎，还是高可用事务，都仍然有大量的优化和探索空间，如何减少事务延迟，如何减少锁的争用，如何减少复制协议的开销，如何实现跨地域事务，都是我们正在探索的问题。如果你对这些问题也同样感兴趣，欢迎加入我们，一起打造一流的分布式数据库！

## 参考

-   [InnoDB Transaction and Write Path](https://mariadb.org/wp-content/uploads/2018/02/Deep-Dive_-InnoDB-Transactions-and-Write-Paths.pdf)
-   [WL#7846: MTS: slave-preserve-commit-order when log-slave-updates/binlog is disabled](https://dev.mysql.com/worklog/task/?id=7846)
-   [WL#9556: Writeset-based MTS dependency tracking on master](https://dev.mysql.com/worklog/task/?id=9556)
-   [WL#5223: Group Commit of Binary Log](https://dev.mysql.com/worklog/task/?id=5223)
-   《An Empirical Evaluation of In-Memory Multi-Version Concurrency Control 》



Reference:

