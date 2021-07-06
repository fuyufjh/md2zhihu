在分布式场景下，如果两表关联条件和表结构定义的分区条件对齐，可以避免网络请求获取数据，PolarDB-X会直接将Join下推，这种方式更为高效。如果是不能下推的场景，且若是一张大表和一张小表做Join，这便是典型的OLTP的关联场景，可以采用PolarDB-X之前提到的[Lookup Join算法](https://zhuanlan.zhihu.com/p/363151441)，也可以获取不错的Join查询性能。但在面对OLAP场景, 数据不可避免都需要从存储获取数据拉出来计算，那么又应该如何高效稳定的做Join呢？

# Join算法实现

数据库面对Join一般区分等值条件的Join和非等值条件的Join，这里咱们主要讲的PolarDB-X在等值Join上的实现和优化，对于等值Join，常见的无外乎就是HashJoin和SortMergeJoin，而HashJoin在是否支持大数据上又可以细分出内存版的HashJoin和支持数据落盘版的HashJoin。

## 内存版的HashJoin

![|center|400x400](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/分布式数据库如何实现Join(二)/1623217771124-88156da2-533c-4d7a-bc21-15ce902b0e00.png) 
针对于两张表的In Memory HashJoin，根据统计信息我们会优先选取其中一张较小表根据Join条件给定的列build hash table，这个过程我们通常称之为**Build Table**。而另外一张表，我们会流式遍历，依次在刚才build的HashMap中进行探测，Key值一致的时候，才会把hash table的值拿出来做比较，满足等值条件，直接向下游输出，这个过程通常称之为**Probe Table**。具体做法的伪代码如下:

```java
//build Table
for row in t1:
    hashValue = hash_func(row)
    put (hashValue, row) into hash-table;

//probe Table
for row in t2:
    hashValue = hash_func(row)
    t1_row = lookup from hash-table 
    if (t1_row != null) {
       join(t1_row, row) 
}
```

整个过程理解起来还是比较简单，都需要拉取两张全量的表。
不过PolarDB-X Hash Join 与一般的的 Hash Join 最大不同在于，用一种内存友好的vector方式重新实现了哈希表, 对 CPU cache 更友好，可以有效提高Join性能。

![|center|800x800](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/分布式数据库如何实现Join(二)/1623217128192-b20d6ee1-5794-4b83-b014-6a1363409d6e.png)

如左上图所示Build端先通过ChunksIndex数据结构缓存所有的数据，ChunksIndex本质上是新建一个 long[] 数组来，其中每个 long 值其实由两个 int 组成，分别表示 Chunk 的标号和 Chunk 内的行编号。依靠这个数据，就可以快速地用一个从 0 开始的连续下标取到任一行数据。基于ChunksIndex的position 连续且唯一的性质，在build hash table的过程，这里使用了对内存访问优化的一个数组（positionLinks）来保存key-value的映射关系。整个过程相比之前逐行按照Object对象构造build表更加高效。
不过当build的数据足够多，无法在内存中全部存下的时候，就容易出现OOM问题，所以我们也支持了HybridHashJoin算法，用来支持大数据情况下的Join。

## HybridHashJoin

HybridHashJoin 是在In Memory HashJoin基础上发展而来的，在这种算法会将Join两侧的数据进行分partition，分别对每个parition里的数据进行HashJoin的运算，如果数据超限，则会将内存占用最大的partition的数据Spill到磁盘，比如下图133 partition的数据被刷到磁盘中，这样可以释放一部分内存，等到其他partition里的数据处理完毕，再重新读取数据进行Join，整个过程是支持不断迭代，整体实现复杂度是远比In Memory HashJoin高。
![|center|600x600](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/分布式数据库如何实现Join(二)/1621837601432-edb61387-4d2f-4dbb-ba34-58d2a6ccd36b.png)
在build Table过程中会把读取到的数据划分到多个partitions中，每个partiton都自己的bucket和对应的数据区，bucket区指向数据区的record，在partition内部build table过程和In Memory HashJoin一样。如果在build时，内存不够用，选取最大的partition来spill, 落盘过程中多半会构建BloomFilter，用于后续的Probe过程。
![|center|600x600](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/分布式数据库如何实现Join(二)/1621839090107-657739c2-d0a7-4248-8463-5eb96154c52b.png)
在Probe Table过程,

1.  读取probe端来进行join，分为两种情况：
    1.  probe这条数据对应的build partition在内存中，过程类似In Memory HashJoin直接join
    1.  probe这条数据对应的partition在磁盘上，此时无法join，只能将probe端数据落盘。(如果有BloomFilter，先过滤)

1.  probe端读取结束后，也分为两种情况：
    1.  如果不存在spill partition，那么join结束
    1.  如果存在spill partition，逐个处理spill的partition，读取当前spill partition的build端数据，新建build table，build table结束后，再读取对应spill partition的probe端数据做Join。如果在这个过程中partition的内存依然无法全放到内存，那么就需要对partition内的数据进一步spill，反复recursive。

HybridHashJoin 在处理过程中，相对于In Memory HashJoin的基础上对抽象了一层partition，理论上会多一次寻址过程。PolarDB-X 完整高效的实现了 Hybrid HashJoin 算法，不过当内存足够的时候，选择使用In Memory HashJoin更为高效。

## SortMergeJoin

除了上面提到的HashJoin以外，PolarDB-X也实现了SortMergeJoin，SortMergeJoin顾名思义就是先同时对两边的数据排序(如果输入已经有序，可以忽略)，然后再两边的数据做Join。这种算法理解和实现，其实都比较简单, 其伪代码如下

```java
sort t1, sort t2
R1 = t1.next()
R2 = t2.next()
while (R1 != null && R2 != null) {
   if R1 joins with R2  
      output (R1, R2)
   else if R1 < R2  
      R1 = t1.next()
   else
      R2 = t2.next()
}
```

这种算法的优点是适用范围广，所有的Join类型都可以处理。而且可以做到流式的处理过程，计算过程中的内存占用也较少，因为两张表没有处理的先后次序关系，允许更高的并行度。缺点是在MPP场景下两侧的数据都要进行shuffle，而且都要进行排序，在数据量较大的情况下，外排又会产生额外的IO，导致性能较差。所以一般HashJoin会比较高效，但是存在一些极端场景，当数据存在大量重复或者哈希冲突严重的场景中，也有可能一个桶中的数据依然超限，则要进行再次分桶，而对应的Probe侧的数据也要再进行Spill，这种场景下SortMergeJoin优势会明显点。
针对于Join，PolarDB-X 基本支持了常见的物理算法，在查询过程中优化器会根据不同场景和统计信息，基于代价去选择合适的物理实现。

# Shuffle Join

在OLAP场景下的多表Join，往往涉及到的数量量比较大，所以需要利用MPP的能力，提高并发度做Join。涉及到多个节点就避免不了数据在网络层的交互，就像下图一样。
![|center|500x500](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/分布式数据库如何实现Join(二)/1623218415959-f492516c-8a33-485b-806b-8a32e5b50c36.png) 
整个执行过程分为两个阶段：

1.  repartition shuffle阶段：分别将两个表按照join key进行分区，将相同join key的记录重分布到同一节点，两张表的数据会被重分布到集群中所有节点。

1.  hash join阶段：每个分区节点上的数据单独执行单机hash join或者sort-merge-join算法。

整个执行过程相对于单机Join算法，代价上多出了对带宽的使用: ，但充分利用了集群资源并行化执行。

除此之后，我们也支持另外一种shuffle策略。Broadcast Join是将其中一张表广播分发到另一张大表所在的分区节点上，分别并发地与其上的分区记录进行Join，这样做的好处可以避免另外一张表做网络shuffle，毕竟数据通过网络是有代价的。一般是小表和大表Join的场景下，我们才会考虑Broadcast Join。
![|center|600x600](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/分布式数据库如何实现Join(二)/1623218434570-7a62120c-3f3e-41ad-bf8a-60cfb665448c.png)
如何选择不同的shuffle策略，这个事情我们会是交给优化器来做的。 一般要求选择broadcast shuffle策略数据在网络传输上代价最小，其中假设T1是更小表，N是需要广播的份数，必须满足以下条件:
                                                $Net(T2 + T2) >  N * Net(T1)$
即便小表broadcast shuffle，但是总体的网络代价依然小于两个表同时做网络传输。

结合上面提到的三种常用的Join算法，和这里提到的两种shuffle策略，PolarDB-X在OLAP场景下做关联操作的时候，就有6种可能性，但在实际生产上，要考虑的点可能更复杂。比如一条三张大表关联（AXBXC)的查询, 其中C表在对应的关联条件上刚好有全局二级索引。如果所有关联操作都选择TP类的LookupJoin，那么AXB需要多次Lookup，性能肯定不好；如果都选择了AP类型的shuffle hash join，虽然可以使用mpp加速，但是同时要扫描三张大表，IO易成为瓶颈，要用更多的CPU做计算，性能也不一定是最好的。那么如果将OLAP Join和OLTP Join算法结合，可以取得更好的效果。A表和B表做MPP场景的shuffle join，利用多核优势加速查询，对查询的结果和C表做LookupJoin，虽然中间有回表和多次网络交互，但避免了大表扫描，利用索引的优势整体的查询代价更低。

![|center|600x600](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/分布式数据库如何实现Join(二)/1623220675624-860c55dd-88f9-43d3-b375-f1b47710d251.png)

# Join的其他优化

除了上述提到的Join优化以外，这里还想和大家交流一下其他比较不错点。

1.  Runtime Filter Join，其基本原理在Join的build table过程中，提前构建BloomFilter, 然后把BloomFilter下推到Probe Table节点上去，在probe端提前过滤掉那些不会命中join的输入数据来大幅减少join中的数据传输和计算，从而减少整体的执行时间。具体的原理可以去查看[查询性能优化之Runtime Filter](https://zhuanlan.zhihu.com/p/374143999)
1.  LongHashJoin，其基本原理是当Join Keys都是数值类型，可以压缩成long来表示join key，这样构建hash table和join条件比较的时候，直接利用long来做，更为高效；此外如果知道build table过程中，join key值分布的区间很窄，那么可以直接利用数组来代替hash table，这样做join也会比较高效
1.  Skewed Join，在两张表Join过程中，可能由于Partition之间的数据分布不均为，导致执行的有快有慢，最慢的可能导致不可忍受。这样我们可以基于统计信息，把数据倾斜比较大的区间单独捞出来，通过增长并发度来加速Join。比如：

`select A.id from A join B on A.id = B.id`
如果key为1的数据量特别大，经过改写成：
`select A.id from A join B on A.id = B.id where A.id <> 1 union all select A.id from A join B on A.id = B.id where A.id = 1 and B.id = 1` 
两条join查询，再做union。这样可以提高并行度，加速查询。
3. NestLoopJoin，一般我们都会认为在NestLoopJoin性能不好，因为在计算过程中它需要套用两层 For 循环，那么如果一张表只有一条数据呢，利用NestLoopJoin性能会比HashJoin好，省去构建build table的开销和probe table过程。

此外在HashJoin计算过程中，我们可以探测一下probe端的输入，如果probe的输入数据为空，那么可以提前结束关联查询。所以在分布式数据库上做Join，可以做的优化很多。而PolarDB-X为了帮助用户更高效的处理关联业务，在关联操作上，会持续关注业界动态，不断融入更好的实现。

# 参考资料

1.  [SQL Server – Hash Join Execution Internals](https://www.sqlshack.com/hash-join-execution-internals/)
1.  [Spark SQL Adaptive Execution at 100 TB](https://software.intel.com/content/www/us/en/develop/articles/spark-sql-adaptive-execution-at-100-tb.html)
1.  [Nested Loop, Hash and Merge Joins](https://tomyrhymond.wordpress.com/2011/10/01/nested-loop-hash-and-merge-joins/)



Reference:

