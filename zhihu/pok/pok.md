## 背景

随着云的兴起，各类云原生技术也发展得欣欣向荣，其中最具代表性的一个就是 Kubernetes。Kubernetes 是一个用于自动部署、管理容器化应用的系统。最初 Kubernetes 是由 Google 公司主导开发的，后来 Google 将它捐献给了云原生计算基金会 CNCF。Kubernetes 能够管理成百上千台机器，并为在上面运行容器应用提供强大而稳定的基础设施。

PolarDB-X 是由阿里云数据库团队打造的一款云原生分布式数据库，它的整个资源管理和调度是构建在 Kubernetes 之上。Kubernetes 统一的资源抽象和管理能力可以很好地满足 PolarDB-X 的两种交付形态：On-Demand 和 On-Premise。通常来说，线下传统的电信、金融等行业有机器利旧的诉求，因此基于 Kubernetes 的 On-Premise 标准轻量化模式将是一个很好的选择。

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/pok/1623461633681-05cc93cd-cb78-493f-8b3f-25e37eecbfa1.png)

<table>
<tr class="header">
<th>交付形态</th>
<th>版本代号</th>
<th>具体定位</th>
<th>内核形态</th>
<th>管控形态</th>
<th>生态工具</th>
<th>属性</th>
</tr>
<tr class="odd">
<td>公共云</td>
<td>主版本</td>
<td>捆绑阿里云硬件，以On-Demand为主</td>
<td></td>
<td></td>
<td></td>
<td></td>
</tr>
</table>

企业版功能整体对齐主版本 | 内核版本统一 | Kubernetes
(All In) | 自带数据库生态工具(比如DTS/DBS/DMS) | 商业版 |
| 混合云 | 企业版 |  |  |  |  |  |
|  | DBStack | 允许用户"自有"硬件，以On-Premise为主
支持金融两地三中心、三权分立等行业需求 |  |  |  |  |
|  | Lite | 允许用户"自有"硬件，以On-Premise为主
PolarDB-X数据库单产品交付 |  |  | 不捆绑生态工具，推荐用户使用开源生态 | 社区版
(后续对外开放可下载) |

上表中详细展示了 PolarDB-X 在公有云和混合云的几个交付形态，本文主要介绍其中的 Lite 社区版本。借助以 Kubernetes 为代表的开源生态，我们构建了一个轻量化的、包含数据库核心功能（基本生命周期、服务高可用、数据备份恢复、审计监控等）的、易运维的软件版本，从而使用户可以快速地在任意硬件上部署和搭建出一个分布式数据库。接下来，文章将从产品形态和技术原理两个视角来介绍下 PolarDB-X Lite。

注：阅读本文需要一定的 Kubernetes 知识，如不熟悉的同学可以参考[官方中文文档](https://kubernetes.io/zh/docs/home/)。

## 视频演示

首先用一个 demo 演示一下我们是如何在 Kubernetes 上运行 PolarDB-X Lite 的。

[此处有视频，录音施工中]

## 产品形态

下图展示了一个 PolarDB-X Lite on Kubernetes 的整体架构图，可以看到最底层是 Kubernetes，而上面是 PolarDB-X 的控制面和 Prometheus 等开源的生态。
![image.png](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/pok/1624244441766-6c386c19-4c41-4bee-a7d8-e273dc0c461b.png)
其中 PolarDB-X 控制面中包含两个主要组件：

-   PolarDB-X Operator，负责整个 PolarDB-X 集群的生命周期维护和其他运维能力
-   XCluster Operator，负责 GMS、DN 的三节点小集群的生命周期维护和运维能力

有了 PolarDB-X 控制面的组件，就可以在 Kubernetes 上创建任意规格的 PolarDB-X 集群。截至目前，我们已经能够在最小 2c8g 的 ECS 上拉起一个完整集群（1 CN + 1 DN + 1 GMS + 1 CDC），最大尝试过搭建一个 100 CN + 100 DN 的集群。除了生命周期管理之外，控制面还支持了以下这些核心能力：

-   弹性伸缩能力，包括水平、垂直扩缩容、数据自均衡
    -   其中的读写分离目前处于规划中

-   高可用能力和容灾部署
-   备份恢复、CDC

为了保证这个部署形态的稳定性，我们将各种测试方案也搬到了 Kubernetes 中，在内部我们已经使用该形态构建了日常的测试回归环境。另外，借助 Prometheus + Grafana + Loki 的开源监控、日志解决方案，我们定制了 PolarDB-X 上的监控和 SQL 审计分析方案，提供了基础的运维能力。

## 技术原理

### 基本构成

Kubernetes 提供了许多可扩展的能力，我们使用了其中的定制资源（Custom Resource）来描述 PolarDB-X 集群，通过实现对应的控制器来实现所需要的功能。下面是核心定制资源 PolarDBXCluster 的一个例子：

```yaml
apiVersion: polardbx.aliyun.com/v1alpha1
kind: PolarDBXCluster
metadata:
  name: test
spec:
  topology:
    cnReplicas: 2
    cnTemplate:
      image: cn-engine
      resources:
        limits:
          cpu: 2
          memory: 4Gi
    dnReplicas: 2
    dnTemplate:
      image: dn-engine
      resources:
        limits:
          cpu: 2
          memory: 4Gi
```

按照 Kubernetes 对定制资源的要求，metadata 部分声明了资源的名字 `test` ，spec 里则定义了数据库集群的拓扑结构 —— 2 个 2C4G 的 CN 和 2 个 2C4G 的 DN。这里 GMS 没有显式的定义，而是隐式地包含在 DN 的规格中，实际上也可以单独声明。

如上一节架构中所述，当这个 yaml 文件被同步到 Kubernetes 中时，我们的控制器 —— 也就是 PolarDB-X Operator 会接收到一个事件并开始创建并维护集群。这个过程在 Kubernetes 中被称为调和循环（reconcilation loop）。调和循环可以简单的用下图来描述：

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/pok/1623390241225-c31f48a5-987b-4761-bdf6-5bd9e3804c79.png)

因为数据库服务是有状态的服务，因此无法像 Deployment 等工作负载一样简单的加减 Pod 来实现。观察上面的集群结构发现，CN 和 CDC 是无状态的，因此可以用 Deployment/ReplicaSet 等工作负载管理，只有 GMS 和 DN 这些带状态（存储）的节点需要特殊的处理。Kubernetes 中提供了 StatefulSet 用来管理有状态的 Pod，虽然它并不能管理其他资源，但是我们可以借鉴它的思想。我们在 PolarDB-X 的控制器中实现了一个类似 StatefulSet 的负载控制器，用来控制 GMS 和 DN 节点。所以 PolarDB-X 在 Kubernetes 中的整体结构大概如下图所示：

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/pok/1623396025705-97396c19-39b5-4290-b97f-4247f2a40838.png)
其中的 CN 和 CDC 都是以 Pod 形式存在，GMS 和 DN 则是另外的定制资源。

在数据库集群的生命周期中，需要处理一系列的状态变化。传统的管控模型下负责处理状态变化的通常是一个独立的任务流组件，任务一步步完成后状态转移，而在 operator 模式中并不推荐如此去做，或者说 operator 本身就是状态机+任务流。我们再 operator 中实现了一个可重入的状态机，将轻任务（例如元数据变更）放在状态转移的过程中，而将重任务（例如备份）放在单独的 Job 中。下图展示了数据库集群的整个状态变化过程：

![](https://cdn.jsdelivr.net/gh/fuyufjh/md2zhihu@_md2zhihu_Downloads_40b3de68/zhihu/pok/1623395801290-b1afed62-b6f2-4ac5-ba6d-76f994490572.png)

PolarDB-X 的控制器就是要实现所有的状态变化过程。这里有一个有意思的地方，为什么还用状态机？实际上状态机并不能处理所有情况，举个例子：在扩容过程中，某个 DN 的机器挂了，这种情况怎么处理？如果不处理的话，看上去并没有完整实现 Kubernetes 的调和循环？这些问题我们在后续的文章中会进行讨论。

### 高可用

在分布式系统中，高可用是一个很有趣的话题。在 Kubernetes 经典的无负载应用负载中，比如 Deployment 中，用户可以通过增加应用的副本数来避免单点故障。当应用副本（Pod）被删除或者集群内的宿主机发生错误时，控制器会自动创建新的副本（Pod）来维持应用的服务能力。而当某个应用容器出现错误崩溃时，Kubernetes 也会尝试重启容器来保证服务的可靠性。Kubernetes 为每个 Pod 提供了可以自定义的探测接口 liveness probe 和 readiness probe，用于探测 Pod 对应的应用是否存活/可提供服务。

PolarDB-X 中无状态的 CN 和 CDC 就是运用了 Kubernetes 的这种机制来保证高可用。而有状态的 GMS 和 DN 的三节点小集群因为需要考虑存储状态的原因，当 Pod 被删除时恢复不能随意选取宿主机，因此除了使用探测-重启的方法以外还提供了三种更复杂的高可用机制 -- 原地拉起、跨机迁移和备库重搭。细节部分将在后续的文章中展开，最后我们用一个 demo 演示一下 PolarDB-X Lite 版本提供的一些高可用能力。

[此处有视频，录音/字幕施工中]

## 总结

本文介绍了 PolarDB-X Lite 这一种新的轻量级部署形态和基本原理，我们希望能够借助它向客户展示 PolarDB-X 作为分布式数据库的核心和生态能力。未来将基于该形态推出一个面向所有人的开放版本，敬请期待！

## 参考文献

[1] [https://kubernetes.io/zh/](https://kubernetes.io/zh/)
[2] [https://kubernetes.io/zh/docs/concepts/workloads/](https://kubernetes.io/zh/docs/concepts/workloads/)
[3] [https://kubernetes.io/docs/tasks/run-application/run-single-instance-stateful-application/](https://kubernetes.io/docs/tasks/run-application/run-single-instance-stateful-application/)
[4] [https://kubernetes.io/zh/docs/concepts/extend-kubernetes/operator/](https://kubernetes.io/zh/docs/concepts/extend-kubernetes/operator/)
[5] [https://blog.container-solutions.com/kubernetes-operators-explained](https://blog.container-solutions.com/kubernetes-operators-explained)
[6] [https://kubernetes.io/zh/blog/2020/12/02/dont-panic-kubernetes-and-docker/](https://kubernetes.io/zh/blog/2020/12/02/dont-panic-kubernetes-and-docker/)



Reference:

