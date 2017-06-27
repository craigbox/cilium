// Copyright 2016-2017 Authors of Cilium
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/cilium/cilium/pkg/k8s"
	"github.com/cilium/cilium/pkg/nodeaddress"

	. "gopkg.in/check.v1"
	meta_v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	corev1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/pkg/api/v1"
)

// Hook up gocheck into the "go test" runner.
func Test(t *testing.T) { TestingT(t) }

type DaemonSuite struct {
	d *Daemon
}

var _ = Suite(&DaemonSuite{})

func (ds *DaemonSuite) TestuseK8sNodeCIDR(c *C) {
	// Test IPv4
	node1 := v1.Node{
		ObjectMeta: meta_v1.ObjectMeta{
			Name: "node1",
			Annotations: map[string]string{
				k8s.Annotationv4CIDRName: "10.254.0.0/16",
			},
		},
		Spec: v1.NodeSpec{
			PodCIDR: "10.2.0.0/16",
		},
	}

	// set buffer to 2 to prevent blocking when calling useK8sNodeCIDR
	updateChan := make(chan bool, 2)
	ds.d.k8sClient = &Clientset{
		OnCoreV1: func() corev1.CoreV1Interface {
			return &CoreV1Client{
				OnNodes: func() corev1.NodeInterface {
					return &NodeInterfaceClient{
						OnGet: func(name string, options meta_v1.GetOptions) (*v1.Node, error) {
							c.Assert(name, Equals, "node1")
							c.Assert(options, DeepEquals, meta_v1.GetOptions{})
							n1copy := v1.Node(node1)
							return &n1copy, nil
						},
						OnUpdate: func(n *v1.Node) (*v1.Node, error) {
							updateChan <- true
							n1copy := v1.Node(node1)
							n1copy.Annotations[k8s.Annotationv4CIDRName] = "10.2.0.0/16"
							n1copy.Annotations[k8s.Annotationv6CIDRName] = "beef:beef:beef:beef:aaaa:aaaa:1111:0/112"
							c.Assert(n, DeepEquals, &n1copy)
							return &n1copy, nil
						},
					}
				},
			}
		},
	}

	err := ds.d.useK8sNodeCIDR("node1")
	c.Assert(err, IsNil)
	select {
	case <-updateChan:
	case <-time.Tick(5 * time.Second):
		c.Errorf("d.k8sClient.CoreV1().Nodes().Update() was not called")
		c.FailNow()
	}
	c.Assert(nodeaddress.IPv4Address.IP().Equal(net.ParseIP("10.2.0.1")), Equals, true)
	c.Assert(nodeaddress.IPv6Address.IP().Equal(net.ParseIP("beef:beef:beef:beef:aaaa:aaaa:1111:0")), Equals, true)

	// Test IPv6
	node1 = v1.Node{
		ObjectMeta: meta_v1.ObjectMeta{
			Name: "node2",
			Annotations: map[string]string{
				k8s.Annotationv4CIDRName: "10.254.0.0/16",
			},
		},
		Spec: v1.NodeSpec{
			PodCIDR: "aaaa:aaaa:aaaa:aaaa:beef:beef::/112",
		},
	}

	failAttempts := 0
	ds.d.k8sClient = &Clientset{
		OnCoreV1: func() corev1.CoreV1Interface {
			return &CoreV1Client{
				OnNodes: func() corev1.NodeInterface {
					return &NodeInterfaceClient{
						OnGet: func(name string, options meta_v1.GetOptions) (*v1.Node, error) {
							c.Assert(name, Equals, "node2")
							c.Assert(options, DeepEquals, meta_v1.GetOptions{})
							n1copy := v1.Node(node1)
							return &n1copy, nil
						},
						OnUpdate: func(n *v1.Node) (*v1.Node, error) {
							// also test retrying in case of error
							if failAttempts == 0 {
								failAttempts++
								return nil, fmt.Errorf("failing on purpose")
							}
							updateChan <- true
							n1copy := v1.Node(node1)
							n1copy.Annotations[k8s.Annotationv4CIDRName] = "10.2.0.0/16"
							n1copy.Annotations[k8s.Annotationv6CIDRName] = "aaaa:aaaa:aaaa:aaaa:beef:beef::/112"
							c.Assert(n, DeepEquals, &n1copy)
							return &n1copy, nil
						},
					}
				},
			}
		},
	}

	err = ds.d.useK8sNodeCIDR("node2")
	c.Assert(err, IsNil)
	select {
	case <-updateChan:
	case <-time.Tick(5 * time.Second):
		c.Errorf("d.k8sClient.CoreV1().Nodes().Update() was not called")
		c.FailNow()
	}
	c.Assert(nodeaddress.IPv4Address.IP().Equal(net.ParseIP("10.2.0.1")), Equals, true)
	c.Assert(nodeaddress.IPv6Address.IP().Equal(net.ParseIP("aaaa:aaaa:aaaa:aaaa:beef:beef::")), Equals, true)
}
