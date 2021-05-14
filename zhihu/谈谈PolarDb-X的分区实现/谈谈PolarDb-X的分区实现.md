# 谈谈PolarDb-X的分区实现

### 1 Hash分区 vs. Range分区

用户在使用分布式数据库时，最想要是既能将计算压力均摊到不同的计算节点(CN)，又能将数据尽量的散列在不同的存储节点(DN)，能让系统的存储压力均摊到不同的DN，对于将计算压力均摊到不同的CN节点，业界的方案一般比较统一，通过的负载均衡调度，将业务的请求均匀的调度到不同的CN节点；对于如何的将数据打散到DN节点，不同的数据库厂商有不同策略，主要是两种流派：按拆分键Hash分区和按拆分键Range分区，DN节点和分片之间的对应关系是由数据库存储调度器来处理的，一般只要数据能均匀打散到不同的分区，那么DN节点之间的数据基本就是均匀的。如下图所示，左边是表A按照列PK做Hash分区的方式创建4个分区，右边是表A按照列PK的值做Range分区的方式也创建4个分区：

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614586715136-0aa041e1-046f-4483-b74f-7af473ad84e7.png)

按照Hash分区的方式，表A的数据会随机的散落在4个分区中，这四个分区的数据之间没有什么的依赖关系，这种方式的优点是：

1.  只要分区键的区分度高，数据一定能打散；
1.  不管是随机写入/读取还是按PK顺序写入/读取，流量都能均匀的分布到这个4个分区中。

Hash分区的缺点是，范围查询非常低效，由于数据随机打散到不同分片列，所以对于范围查询只能通过全部扫描才能找到全部所需的数据，只有等值查询才能做分区裁剪。

按照Range分区的方式，根据定义，表A会被切分成4个分区，pk为1～1000范围内的值散落到分区1，pk为1001～2000范围内的值散落到分区2，pk为2001～3000范围内的值散落到分区3，pk为3001～4000范围内的值散落到分区4，由于数据在分区内是连续的，所以Range分区有个很好的特性就是范围查询很高效，例如：

```sql
select * from A where PK >2 and PK < 500
```

对于这个查询我们只有扫描分区1就可以，其他分区可以裁剪掉。

Range分区方式的缺点是：

1.  如果各个分区范围的数据不均衡，例如pk为[1,1000]的数据只有10条，而pk为[1001,2000]的数据有1000条，就会发生数据倾斜。所以数据能不能均衡散列跟数据的分布性有关。
1.  对于按照拆分列（如例子中的PK列）顺序读取或者写入，那么读或许写的流量永远都在最后一个分区，最后一个分片将成为热点分片。

### 2 默认拆分方式

为了让用户能用较小代价从单机数据库到分布式数据库的演进，将原有数据表的schema结构导入到分布式数据系统中，再将数据导入就可以将现有表的数据打散到不同的DN节点，而不需要像我们前面例子中一样，额外添加 `partition by hash/range` 这样的语句，一般的分布式数据都会按照某种默认策略将数据打散。业界有默认两种策略，一种是默认按主键Hash拆分（如yugabyteDB），一种是默认按主键Range拆分(如TiDB)。这两种拆分方式各有什么优缺点，在PolarDB-X中我们采取什么样的策略？我们一起来探索一下。

#### 2.1 主键Hash拆分

默认按主键Hash拆分，意味着用户在创建表的时候不需要显式指定拆分方式的时候会自动的将插入数据库每一行的主键通过hash散列后得到一个HashKey，在根据*****:emphasis**，从而实现将数据散列到不同的DN节点的目的。

常见的HashKey和DN的映射策略有两种方式，按Hash得到的结果取模 (hashKey % n) 和 一致性Hash(将hashKey划分成不同的range，每个range和不同的DN对应)

**按Hash结果(hashKey % n)取模**

这里的n是存储节点的数量，这个方法很简单，就是将拆分键的值按照hash function计算出一个hashKey后，将这个hashKey对存储节点数量n取模得到一个值，这个值就是存储节点的编号。所以数据和DN节点的具体的映射关系如下：

DN = F(input) ==> DN = Hash(pk) % n

例如系统中有4个DN节点，加入假如插入的行的pk=1，hash(1)的结果为200，那么这一行最终将落在第0个DN节点（200%4=0）

按hash key取模的方法优点是：用户能够根据hashkey的值和DN的数量可以精准的计算出数据落在哪个DN上，可以灵活的通过hint控制从哪个DN读写数据。

按hash key取模的方法缺点是，当往集群增加或者减少DN节点的时候，由于DN的数目就是hash取模的n的值，所以只要发生DN节点的变化都需要将原有的数据rehash 从新打散到现有的DN节点，代价是非常的大的。同时这种分区方式对于范围查询不友好，因为数据按hashKey散列到不同的DN，只有全表扫描之后才能找到所需数据。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614591092176-1838b4e2-3d93-4e92-a182-e24084f7bb6c.png)

**一致性Hash**

一致性Hash是一种特殊的Hash算法，先根据拆分键（主键）的值按照hash function计算一个hashKey，然后再将hashKey定位到对应的分片的分区方式，效果上类似于  Range By (hashFunction(pk)) , 假设计算出来的HashKey的大小全部都是落在[0x0,0xFFFF]区间内，当前系统有4个DN节点，建表可以默认创建4个分区，那么每个分区就可以分配到不同的DN节点，每个分区对应的区间如下图：

```
0x～0x4000(左开右合区间)
0x4000～0x8000
0x8000~0xc000
0xc000~0x10000
```

分区和DN之间的对应关系作为表结构的元数据保存起来，这样我们得到主键的HashKey之后，根据这个HashKey的值的范围和分区的元数据信息做个二分查找，就可以计算出该主键所在的行落在哪个区分, 具体的计算公式如下：

DN = F(input) ==> DN = BiSearch(Hash(pk))

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614591669770-b9d11c0b-662a-438f-96af-f7d5e956f049.png)

一致性Hash的方法的优点是当添加DN节点是我们可以将部分分片数据通过分裂或者迁移的方式挪到新的DN，同时更新一下表的元数据，其他的分片数据无需变化，当减少DN节点时，也只需要将待删除的DN节点上的数据迁移到其他节点同时更新一下元数据即可，非常的灵活，一致性Hash的方法的缺点是对范围查询也不友好

#### 2.2 主键Range拆分

主键range拆分的方式和一致性Hash的本质区别在于，一致性Hash是对拆分键的Hash后得到HashKey，按这个HashKey的取值范围切分成不同的分区，主键range拆分是按将拆分键的实际值的取值范围拆分不同的分区。对按照主键拆分的表，优点是范围查询非常的高效，因为PK相邻的数据分区也是相同或者相邻的；还可以实现快速删除，例如对于是基于时间range分区的表，我们可以很轻松的将某个时间点之前的数据全部删掉，因为只需要将对应的分区删除就可以了，其他分区的数据可以保持不变，这些特性都是按hash分区无法做到的，缺点是在使用自增主键并且连续插入的场景下，最后一个分片一定会成为写入热点。

#### 2.3 PolarDB-X的默认拆分方式

了解了这两种默认的主键拆分方式后我们来谈谈PolarDB-X是如何取舍的。本质上范围查询和顺序写入是个矛盾点，如果要支持高效的范围查询，那么在按主键递增顺序写入就一定会成为热点，毕竟范围查询之所以高效是相邻的主键在存储物理位置也是相邻的，存储位置相邻意味着按主键顺序写入一定会只写最后一个分片。对于OLAP的场景，可能问题不大， 毕竟数据主要的场景是读，但对于OLTP场景，就不一样了，很多业务需要快速的生成一个唯一的ID，通过业务系统生成一个UUID的方式是低效的，存储代价也比AUTO_INCREMENT列大。

对一个主键做范围查询不场景不是很常见，除非这个主键是时间类型，例如某订单表按照创建一个主键为gmt_create的时间类型，为了高效的查找某段时间范围内的订单，可能会有范围查询的诉求。

基于以上分析，在PolarDB-X中我们是默认按主键Hash拆分，在Hash算法的选择中，我们选用的是一致性Hash的路由策略，因为我们认为在分布式数据库系统，节点的变更，分区的分裂合并是很常见的，前面分析过使用Hash取模的方式对于这种操作代价太大了，一致性Hash能保证我们分区的分裂合并，增删DN节点的代价做到和Range分区一样，能做到按需移动数据，而不需要全部的rehash。

特别的，对于主键是时间类型，我们默认是按时间取YYYYDD表达式作用于pk后再按一致性Hash打散，这样做的目的是同一天的数据会落在同一个分区，数据能以天为单位打散，这种方式对于按主键（时间）做范围查询是高效的，前面我们提到过，对于以时间为主键的表，范围查询是个强诉求，同时能更高效将历史数据（例如，一年前的数据）归档。

### 3 table group

在PolarDB-X中，为加速SQL的执行效率，优化器针会将分区表之间Join操作优化为Partition-Wise Join来做计算下推。但是，当分区表的拓扑发生变更后，例如分区发生分裂或者合并后，原本分区方式完全相同的两张分区表，就有可能出现分区方区不一致，这导致这两张表之间的计算下推会出现失效，进而对业务产生直接影响。

对于以下的两个表t1和t2, 由于它们的分区类型/拆分键类型/分区的数目等都是一致，我们认为这两个表的分区规则是完全一致的

```sql
create table t1 (c1 int auto_increment, c2 varchar(20), c3 int, c4 date, primary key(c1))
    	PARTITION BY HASH (c1) partition 4

create table t2 (c2 int auto_increment, c2 varchar(20), primary key(c2))
    	PARTITION BY HASH (c2) partition 4
```

所以在这两个表上，执行sql1： select t1.c1, t2.c1 from t1, t2 on t1.c1 = t2.c2，对于这种按照分区键做equi-join的sql, PolarDB-X会优化为Partition-Wise Join将其下推到存储节点将join的结果直接返回给CN，而无需将数据拉取到CN节点再做join，从而大大的降低join的代价(io和计算的代价都大大的减少)。

但是如果t1表的p1发生了分裂，分区数目将从4个变成了5个，这时候sql1就不能再下推了，因为t1和t2的分区方式不完整一致了，左右表join所需的数据发生在多个DN节点，必须将数据从DN节点拉取到CN节点才能做join了。

为了解决分区表在分裂或合并过程中导致的计算下推失效的问题，我们创造性的引入了表组（Table Group）和分区组（partition group）的概念，允许用户将两张及以上的分区表分区定义一致的表划分到同一个表组内，在同一个表组的所有表的分区规则都是一致的，相同规则的分区属于同一个分区组，在一个分区组的所有分区都在同一个DN节点(join下推的前提)，属于同一个表组的分区表的分裂合并迁移都是以分区组为基本单位，要么同时分裂，要么同时合并，要么同时迁移，总是保持同步，即使表组内的分区表的分区出现变更，也不会对表组内原来能下推的join产生影响。

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614602862441-109cedb6-e9c8-429e-9b17-d3bc241afe82.png)

特别的，为了减少用户的学习成本，一开始用户并不需要关注表组，我们会默认将每个表都单独放到一个表组里，用户并不用感知它。只有在需要性能调优或者业务中某些表需要稳定的做join下推时，作为一种最佳实践，这时候用户才需要考虑表组。

对于表组我们支持如下的管理方式有
表组分区组分裂：

一般的，在PolarDB-X中，一个分区表的大小建议维持在500W以内，当一个分区的数据量太大，我们可以对分区进行分裂操作，

```sql
alter tablegroup split partition p1 to p10, p11
```

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614603717896-05b1fc83-cb50-4c58-8d51-797963ab73f0.png)

表组分区组合并：

当一个分区表的某些分区的行数大小远小于500W时，我们可以对分区进行合并操作，

```sql
alter tablegroup merge partition p1,p2 to p10
```

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614603904142-5005e36c-4dce-47a3-8e64-0ee0ed5975c7.png)

表组分区组的迁移：

前面我们提到在分布式数据库系统中，节点的增加或者减少是很常见的事情，例如某商家为了线上促销，会临时的增加一批节点，在促销结束后希望将节点缩容会平时正常的量。PolarDB-X中我们是如何支持这种诉求的？
PolarDB-X的CN节点是无状态的, 增删过程只需往系统注册，不涉及数据移动。这里主要讨论增删DN节点，当用户通过升配增加DN节点后，这个DN节点一开始是没有任何数据的，我们怎么快速的让这个新的DN节点能分摊系统的流量呢？在DN节点准备好后，我们后台的管控系统可以通过PolarDB-X提供的分区迁移命令可以按需的批量将数据从老DN节点迁移到新的DN，具体命令如下：

```sql
alter tablegroup move partition p1,p2 to DNi
```

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614604038882-47528719-3e71-4d76-9964-fb621b9d422e.png)

将表D加入表组tg1：

```sql
alter tablegroup tg1 add D
```

将表D加入表组tg1有个前提条件，就是表D的分区方式要和tg1里的表完全一致，同时如果对应分区的数据和tg1对应的分区组不在同一个DN节点，会触发表D的数据迁移
![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614610077922-94700476-75ae-43c3-a13c-d7cf38036168.png)

将表B从表组tg中移除：

```sql
alter tablegroup tg1 remove B
```

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614610753267-a183c062-a99a-4ef6-ba7c-3f0f466ee24e.png)

### 4 其他分区方式

前面我们对比了一致性Hash和Range的区别，并且我们采用默认按主键拆分的策略，尽管如此我们还是实现了Range分区和List分区以满足客户不同场景的不同诉求

#### 4.1 Range分区

特别的提一下，range分区除了上面提到的范围查询优化的有点外，在PolarDB-X中，我们的存储引擎不光支持Innodb，还有我们自研的X-Engine，X-Engine的LSM-tree的分层结构支持混合存储介质，通过range分区可以按需的将业务任务的是“老分区”的数据迁移到X-Engine，对于迁移过来的冷数据，可以保存在比较廉价的HDD硬盘中，对于热数据可以存储在SSD，从而实现冷热数据的分离。

#### 4.2 List分区

list分区是实现按照离散的值划分分区的一种策略，有了list分区的支持，那么在PolarDB-X中就可以实现Geo Partition的方案，例如对于某个系统，里面有全球各个国家的数据，那么就可以按照欧美-亚太-非洲等区域维度拆分，将不同的分区部署在不同地域的物理机房，将数据放在离用户更近的地域，减少访问延迟。

```sql
CREATE TABLE users （ country varchar, id int, name varchar, …)
PARTITION BY LIST (country) (
    PARTITION Asia VALUES IN ('CN', 'JP', …),
    PARTITION Europe VALUES IN ('GE','FR',..),
    ....
)
```

#### 4.3 组合分区

前面提到，在PolarDB-X中我们支持Hash/Range/List分区方式，同时我们也支持这三种分区任意两两组合的二级分，以满足不同业务的不同诉求。下面举几个常见的例子来阐述，如何通过这三种分区的组合解决不同的问题

场景1: 用显式的创建list分区表，例如将省份作为拆分键，将不同省份的数据保存在不同的分片，进而可以将不同身份的分片保存在不同的DN，这样做的好处是可以做到按省份数据隔离，然后可以按照区域将不同省份的数据保存在就近的数据中心（如华南/华北数据中心）。但是这种分区有个缺点，就是力度太粗了，每个省份一个分区，很容易就产生一个很大的分区，而且还没发直接分裂，对于这种场景，可以采用list+hash的组合，一级分区用list划分后，分区内再根据主键hash，就可以将数据打散的非常均匀，如：

```sql
create table AA (pk bigint, provinceName varchar,...) PARTITION BY LIST (provinceName)
SUBPARTITION BY HASH (pk)
SUBPARTITIONS 2
( PARTITION p1 VALUES ('Guangdong','Fujian'),
  PARTITION p2 VALUES ('Beijing','HeBei','Tijin')
);
```

一级分区p1/p2是采用list分区形式，可以将p1的子分区固定在region1，p2的子分区固定在region2，如下图所示：

![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_fuyufjh_2f198899/zhihu/谈谈PolarDb-X的分区实现/1614611666887-2e0fb6c2-465d-4169-808a-72324e1512ca.png)

场景2: 单key热点，当一个key的数据很多时，该key所在的分片会很大，造成该分片可能成为一个热点，PolarDB-X中默认按主键拆分，并不会出现此类热点，因此热点key来自二级索引，因为主表采用来主键Hash拆分，二级索引表的拆分键就会选择和主表不一样的列，对于按非主键列拆分就可能产生热点key，对于热点key，PoalrDB-X首先会将热点key通过分裂的方式，放到一个单独的分片内，随着该分片的负载变大，PolarDB-X会将该分片所在的DN上的其他分片逐步迁移到其他DN上，最终，这个分片将独占一个DN节点。如果该分片独占一个DN节点后，依然无法满足要求，PolarDB-X会对这个分区二级散列成多个分片，进而这个热点key就可以迁移到多台DN上。当分片被打散后，对该key的查询需要聚合来自多个DN的多个分片的数据，在查询上会有一定的性能损失。PolarDB-X对分片的管理比较灵活，对同一个表的不同分片，允许使用不同打散策略。例如对p1分片打散成2个分片，对p2分片打散成3个分片，对p4分片不做打散。避免热点分片对非热点分片的影响。

### 5 小结

PolarDB-X提供了默认按主键Hash分区的分区管理策略，同时为了满足不同业务的需求也支持了Range和List分区，这三种分区策略可以灵活组合，支持二级分区。为了计算下推，引入了表组的概念，满足不同业务的需求。

# Reference

[1] [Online, Asynchronous Schema Change in F1](https://storage.googleapis.com/pub-tools-public-publication-data/pdf/41376.pdf).
[2] [https://docs.oracle.com/en/database/oracle/oracle-database/21/vldbg/](https://docs.oracle.com/en/database/oracle/oracle-database/21/vldbg/)
[3] [https://dev.mysql.com/doc/refman/5.7/en/partitioning-management.html](https://dev.mysql.com/doc/refman/5.7/en/partitioning-management.html)



Reference:

