// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Host Side support for RNDIS Networking Links
 * Tailored for F515 head unit with standalone CDC descriptor parser
 */
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/workqueue.h>
#include <linux/slab.h>
#include <linux/mii.h>
#include <linux/usb.h>
#include <linux/usb/cdc.h>
#include <linux/usb/usbnet.h>
#include <linux/usb/rndis_host.h>

#define driver_of(d) to_usb_driver((d)->dev.driver)

static int my_rndis_cdc_bind(struct usbnet *dev, struct usb_interface *intf)
{
	u8 *buf = intf->cur_altsetting->extra;
	int len = intf->cur_altsetting->extralen;
	struct cdc_state *info = (void *)&dev->data;
	int status;
	struct usb_driver *driver = driver_of(intf);
	struct usb_cdc_parsed_header header;

	memset(info, 0, sizeof(*info));
	info->control = intf;

	if (len == 0 && dev->udev->actconfig->extralen) {
		buf = dev->udev->actconfig->extra;
		len = dev->udev->actconfig->extralen;
	}

	cdc_parse_cdc_header(&header, intf, buf, len);
	info->u = header.usb_cdc_union_desc;
	info->header = header.usb_cdc_header_desc;
	info->ether = header.usb_cdc_ether_desc;

	if (info->u) {
		info->control = usb_ifnum_to_if(dev->udev, info->u->bMasterInterface0);
		info->data = usb_ifnum_to_if(dev->udev, info->u->bSlaveInterface0);
	}
	if (!info->control || !info->data) {
		info->control = usb_ifnum_to_if(dev->udev, 0);
		info->data = usb_ifnum_to_if(dev->udev, 1);
	}
	if (!info->control || !info->data || info->control != intf) {
		dev_err(&intf->dev, "RNDIS: cannot find control/data interfaces\n");
		return -ENODEV;
	}

	if (info->data != info->control) {
		status = usb_driver_claim_interface(driver, info->data, dev);
		if (status < 0)
			return status;
	}

	status = usbnet_get_endpoints(dev, info->data);
	if (status < 0) {
		usb_set_intfdata(info->data, NULL);
		if (info->data != info->control)
			usb_driver_release_interface(driver, info->data);
		return status;
	}

	if (info->data != info->control)
		dev->status = NULL;
	if (info->control->cur_altsetting->desc.bNumEndpoints == 1) {
		struct usb_endpoint_descriptor *desc;
		dev->status = &info->control->cur_altsetting->endpoint[0];
		desc = &dev->status->desc;
		if (!usb_endpoint_is_int_in(desc) ||
		    (le16_to_cpu(desc->wMaxPacketSize) < sizeof(struct usb_cdc_notification)) ||
		    !desc->bInterval) {
			dev->status = NULL;
		}
	}
	if (!dev->status) {
		dev_err(&intf->dev, "missing RNDIS status endpoint\n");
		usb_set_intfdata(info->data, NULL);
		usb_driver_release_interface(driver, info->data);
		return -ENODEV;
	}

	return 0;
}

void rndis_status(struct usbnet *dev, struct urb *urb)
{
	netdev_dbg(dev->net, "rndis status urb, len %d stat %d\n",
		   urb->actual_length, urb->status);
}
EXPORT_SYMBOL_GPL(rndis_status);

static void rndis_msg_indicate(struct usbnet *dev, struct rndis_indicate *msg,
				int buflen)
{
	struct cdc_state *info = (void *)&dev->data;
	struct device *udev = &info->control->dev;

	if (dev->driver_info->indication) {
		dev->driver_info->indication(dev, msg, buflen);
	} else {
		u32 status = le32_to_cpu(msg->status);

		switch (status) {
		case RNDIS_STATUS_MEDIA_CONNECT:
			dev_info(udev, "rndis media connect\n");
			break;
		case RNDIS_STATUS_MEDIA_DISCONNECT:
			dev_info(udev, "rndis media disconnect\n");
			break;
		default:
			dev_info(udev, "rndis indication: 0x%08x\n", status);
		}
	}
}

int rndis_command(struct usbnet *dev, struct rndis_msg_hdr *buf, int buflen)
{
	struct cdc_state	*info = (void *) &dev->data;
	struct usb_cdc_notification notification;
	int			master_ifnum;
	int			retval;
	int			partial;
	unsigned		count;
	u32			xid = 0, msg_len, request_id, msg_type, rsp,
				status;

	msg_type = le32_to_cpu(buf->msg_type);

	if (likely(msg_type != RNDIS_MSG_HALT && msg_type != RNDIS_MSG_RESET)) {
		xid = dev->xid++;
		if (!xid)
			xid = dev->xid++;
		buf->request_id = (__force __le32) xid;
	}
	master_ifnum = info->control->cur_altsetting->desc.bInterfaceNumber;
	retval = usb_control_msg(dev->udev,
		usb_sndctrlpipe(dev->udev, 0),
		USB_CDC_SEND_ENCAPSULATED_COMMAND,
		USB_TYPE_CLASS | USB_RECIP_INTERFACE,
		0, master_ifnum,
		buf, le32_to_cpu(buf->msg_len),
		RNDIS_CONTROL_TIMEOUT_MS);
	if (unlikely(retval < 0 || xid == 0))
		return retval;

	if (dev->driver_info->data & RNDIS_DRIVER_DATA_POLL_STATUS) {
		retval = usb_interrupt_msg(
			dev->udev,
			usb_rcvintpipe(dev->udev,
				       dev->status->desc.bEndpointAddress),
			&notification, sizeof(notification), &partial,
			RNDIS_CONTROL_TIMEOUT_MS);
		if (unlikely(retval < 0))
			return retval;
	}

	rsp = le32_to_cpu(buf->msg_type) | RNDIS_MSG_COMPLETION;
	for (count = 0; count < 10; count++) {
		memset(buf, 0, CONTROL_BUFFER_SIZE);
		retval = usb_control_msg(dev->udev,
			usb_rcvctrlpipe(dev->udev, 0),
			USB_CDC_GET_ENCAPSULATED_RESPONSE,
			USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE,
			0, master_ifnum,
			buf, buflen,
			RNDIS_CONTROL_TIMEOUT_MS);
		if (likely(retval >= 8)) {
			msg_type = le32_to_cpu(buf->msg_type);
			msg_len = le32_to_cpu(buf->msg_len);
			status = le32_to_cpu(buf->status);
			request_id = (__force u32) buf->request_id;
			if (likely(msg_type == rsp)) {
				if (likely(request_id == xid)) {
					if (unlikely(rsp == RNDIS_MSG_RESET_C))
						return 0;
					if (likely(RNDIS_STATUS_SUCCESS
							== status))
						return 0;
					dev_dbg(&info->control->dev,
						"rndis reply status=0x%08x\n",
						status);
					return -EL3RST;
				}
				dev_dbg(&info->control->dev,
					"rndis reply id %d expected %d\n",
					request_id, xid);
			} else switch (msg_type) {
			case RNDIS_MSG_INDICATE:
				rndis_msg_indicate(dev, (void *)buf, buflen);
				break;
			case RNDIS_MSG_KEEPALIVE:
				buf->msg_type = cpu_to_le32(
						RNDIS_MSG_KEEPALIVE_C);
				buf->msg_len = cpu_to_le32(
						sizeof(struct rndis_keepalive_c));
				buf->status = cpu_to_le32(
						RNDIS_STATUS_SUCCESS);
				retval = usb_control_msg(dev->udev,
					usb_sndctrlpipe(dev->udev, 0),
					USB_CDC_SEND_ENCAPSULATED_COMMAND,
					USB_TYPE_CLASS | USB_RECIP_INTERFACE,
					0, master_ifnum,
					buf, sizeof(struct rndis_keepalive_c),
					RNDIS_CONTROL_TIMEOUT_MS);
				if (unlikely(retval <= 0))
					dev_dbg(&info->control->dev,
						"rndis keepalive err %d\n",
						retval);
				break;
			default:
				dev_dbg(&info->control->dev,
					"unexpected rndis msg %08x len %d\n",
					le32_to_cpu(buf->msg_type),
					msg_len);
			}
		} else {
			dev_dbg(&info->control->dev,
				"rndis response err %d\n", retval);
		}
		msleep(20);
	}
	dev_dbg(&info->control->dev, "rndis response timeout\n");
	return -ETIMEDOUT;
}
EXPORT_SYMBOL_GPL(rndis_command);

static int rndis_query(struct usbnet *dev, struct usb_interface *intf,
		void *buf, u32 oid, u32 in_len,
		void **reply, int *reply_len)
{
	int retval;
	union {
		void			*buf;
		struct rndis_msg_hdr	*header;
		struct rndis_query	*get;
		struct rndis_query_c	*get_c;
	} u;
	u32 off, len;

	u.buf = buf;

	memset(u.get, 0, sizeof *u.get);
	u.get->msg_type = cpu_to_le32(RNDIS_MSG_QUERY);
	u.get->msg_len = cpu_to_le32(sizeof *u.get + in_len);
	u.get->oid = cpu_to_le32(oid);
	u.get->len = cpu_to_le32(in_len);
	u.get->offset = cpu_to_le32(20);

	retval = rndis_command(dev, u.header, CONTROL_BUFFER_SIZE);
	if (unlikely(retval < 0)) {
		dev_err(&intf->dev, "RNDIS_MSG_QUERY(0x%08x) failed, %d\n",
				oid, retval);
		return retval;
	}

	off = le32_to_cpu(u.get_c->offset);
	len = le32_to_cpu(u.get_c->len);
	if (unlikely((8 + off + len) > CONTROL_BUFFER_SIZE))
		goto response_error;

	if (*reply_len != -1 && len != *reply_len)
		goto response_error;

	*reply = (unsigned char *) &u.get_c->request_id + off;
	*reply_len = len;

	return 0;

response_error:
	dev_err(&intf->dev, "RNDIS_MSG_QUERY(0x%08x) invalid response "
			"count/offset: %d/%d\n", oid, len, off);
	return -EDOM;
}

static int rndis_netdev_change_mtu(struct net_device *net, int new_mtu)
{
	struct usbnet *dev = netdev_priv(net);
	if (new_mtu <= 0)
		return -EINVAL;
	net->mtu = new_mtu;
	dev->hard_mtu = net->mtu + net->hard_header_len;
	return 0;
}

static const struct net_device_ops rndis_netdev_ops = {
	.ndo_open		= usbnet_open,
	.ndo_stop		= usbnet_stop,
	.ndo_start_xmit		= usbnet_start_xmit,
	.ndo_tx_timeout		= usbnet_tx_timeout,
	.ndo_get_stats64	= usbnet_get_stats64,
	.ndo_change_mtu		= rndis_netdev_change_mtu,
	.ndo_set_mac_address	= eth_mac_addr,
	.ndo_validate_addr	= eth_validate_addr,
};

int generic_rndis_bind(struct usbnet *dev, struct usb_interface *intf, int flags)
{
	int			retval;
	struct net_device	*net = dev->net;
	struct cdc_state	*info = (void *) &dev->data;
	union {
		void			*buf;
		struct rndis_msg_hdr	*header;
		struct rndis_init	*init;
		struct rndis_init_c	*init_c;
		struct rndis_query	*get;
		struct rndis_query_c	*get_c;
		struct rndis_set	*set;
		struct rndis_set_c	*set_c;
		struct rndis_halt	*halt;
	} u;
	u32			tmp;
	__le32			phym_unspec, *phym;
	int			reply_len;
	unsigned char		*bp;

	u.buf = kmalloc(CONTROL_BUFFER_SIZE, GFP_KERNEL);
	if (!u.buf)
		return -ENOMEM;
	retval = my_rndis_cdc_bind(dev, intf);
	if (retval < 0)
		goto fail;

	u.init->msg_type = cpu_to_le32(RNDIS_MSG_INIT);
	u.init->msg_len = cpu_to_le32(sizeof *u.init);
	u.init->major_version = cpu_to_le32(1);
	u.init->minor_version = cpu_to_le32(0);

	net->hard_header_len += sizeof (struct rndis_data_hdr);
	dev->hard_mtu = net->mtu + net->hard_header_len;

	dev->maxpacket = usb_maxpacket(dev->udev, dev->out, 1);
	if (dev->maxpacket == 0) {
		netif_dbg(dev, probe, dev->net,
			  "dev->maxpacket can't be 0\n");
		retval = -EINVAL;
		goto fail_and_release;
	}

	dev->rx_urb_size = dev->hard_mtu + (dev->maxpacket + 1);
	dev->rx_urb_size &= ~(dev->maxpacket - 1);
	u.init->max_transfer_size = cpu_to_le32(dev->rx_urb_size);

	net->netdev_ops = &rndis_netdev_ops;

	retval = rndis_command(dev, u.header, CONTROL_BUFFER_SIZE);
	if (unlikely(retval < 0)) {
		dev_err(&intf->dev, "RNDIS init failed, %d\n", retval);
		goto fail_and_release;
	}
	tmp = le32_to_cpu(u.init_c->max_transfer_size);
	if (tmp < dev->hard_mtu) {
		if (tmp <= net->hard_header_len) {
			dev_err(&intf->dev,
				"dev can't take %u byte packets (max %u)\n",
				dev->hard_mtu, tmp);
			retval = -EINVAL;
			goto halt_fail_and_release;
		}
		dev_warn(&intf->dev,
			 "dev can't take %u byte packets (max %u), "
			 "adjusting MTU to %u\n",
			 dev->hard_mtu, tmp, tmp - net->hard_header_len);
		dev->hard_mtu = tmp;
		net->mtu = dev->hard_mtu - net->hard_header_len;
	}

	dev_dbg(&intf->dev,
		"hard mtu %u (%u from dev), rx buflen %zu, align %d\n",
		dev->hard_mtu, tmp, dev->rx_urb_size,
		1 << le32_to_cpu(u.init_c->packet_alignment));

	if (dev->driver_info->early_init &&
			dev->driver_info->early_init(dev) != 0)
		goto halt_fail_and_release;

	phym = NULL;
	reply_len = sizeof *phym;
	retval = rndis_query(dev, intf, u.buf,
			     RNDIS_OID_GEN_PHYSICAL_MEDIUM,
			     0, (void **) &phym, &reply_len);
	if (retval != 0 || !phym) {
		phym_unspec = cpu_to_le32(RNDIS_PHYSICAL_MEDIUM_UNSPECIFIED);
		phym = &phym_unspec;
	}

	reply_len = ETH_ALEN;
	retval = rndis_query(dev, intf, u.buf,
			     RNDIS_OID_802_3_PERMANENT_ADDRESS,
			     48, (void **) &bp, &reply_len);
	if (unlikely(retval < 0)) {
		dev_err(&intf->dev, "rndis get ethaddr, %d\n", retval);
		goto halt_fail_and_release;
	}

	if (bp[0] & 0x02)
		eth_hw_addr_random(net);
	else
		ether_addr_copy(net->dev_addr, bp);

	memset(u.set, 0, sizeof *u.set);
	u.set->msg_type = cpu_to_le32(RNDIS_MSG_SET);
	u.set->msg_len = cpu_to_le32(4 + sizeof *u.set);
	u.set->oid = cpu_to_le32(RNDIS_OID_GEN_CURRENT_PACKET_FILTER);
	u.set->len = cpu_to_le32(4);
	u.set->offset = cpu_to_le32((sizeof *u.set) - 8);
	*(__le32 *)(u.buf + sizeof *u.set) = cpu_to_le32(RNDIS_DEFAULT_FILTER);

	retval = rndis_command(dev, u.header, CONTROL_BUFFER_SIZE);
	if (unlikely(retval < 0)) {
		dev_err(&intf->dev, "rndis set packet filter, %d\n", retval);
		goto halt_fail_and_release;
	}

	retval = 0;
	kfree(u.buf);
	return retval;

halt_fail_and_release:
	memset(u.halt, 0, sizeof *u.halt);
	u.halt->msg_type = cpu_to_le32(RNDIS_MSG_HALT);
	u.halt->msg_len = cpu_to_le32(sizeof *u.halt);
	(void) rndis_command(dev, (void *)u.halt, CONTROL_BUFFER_SIZE);
fail_and_release:
	if (info->data) {
		usb_set_intfdata(info->data, NULL);
		usb_driver_release_interface(driver_of(intf), info->data);
	}
fail:
	kfree(u.buf);
	return retval;
}
EXPORT_SYMBOL_GPL(generic_rndis_bind);

static int rndis_bind(struct usbnet *dev, struct usb_interface *intf)
{
	return generic_rndis_bind(dev, intf, 0);
}

void rndis_unbind(struct usbnet *dev, struct usb_interface *intf)
{
	struct cdc_state		*info = (void *) &dev->data;
	struct rndis_halt		*halt;

	halt = kzalloc(CONTROL_BUFFER_SIZE, GFP_KERNEL);
	if (halt) {
		halt->msg_type = cpu_to_le32(RNDIS_MSG_HALT);
		halt->msg_len = cpu_to_le32(sizeof *halt);
		(void) rndis_command(dev, (void *)halt, CONTROL_BUFFER_SIZE);
		kfree(halt);
	}

	if (info->data) {
		usb_set_intfdata(info->data, NULL);
		usb_driver_release_interface(driver_of(intf), info->data);
	}
}
EXPORT_SYMBOL_GPL(rndis_unbind);

int rndis_rx_fixup(struct usbnet *dev, struct sk_buff *skb)
{
	return 1;
}
EXPORT_SYMBOL_GPL(rndis_rx_fixup);

struct sk_buff *
rndis_tx_fixup(struct usbnet *dev, struct sk_buff *skb, gfp_t flags)
{
	struct rndis_data_hdr	*hdr;
	struct sk_buff		*skb2;
	unsigned		len = skb->len;

	if (likely(!skb_cloned(skb))) {
		int	room = skb_headroom(skb);

		if (unlikely((sizeof *hdr) <= room))
			goto fill;

		room += skb_tailroom(skb);
		if (likely((sizeof *hdr) <= room)) {
			skb->data = memmove(skb->head + sizeof *hdr,
					    skb->data, len);
			skb_set_tail_pointer(skb, len);
			goto fill;
		}
	}

	skb2 = skb_copy_expand(skb, sizeof *hdr, 1, flags);
	dev_kfree_skb_any(skb);
	if (unlikely(!skb2))
		return skb2;
	skb = skb2;

fill:
	hdr = __skb_push(skb, sizeof *hdr);
	memset(hdr, 0, sizeof *hdr);
	hdr->msg_type = cpu_to_le32(RNDIS_MSG_PACKET);
	hdr->msg_len = cpu_to_le32(skb->len);
	hdr->data_offset = cpu_to_le32(sizeof(*hdr) - 8);
	hdr->data_len = cpu_to_le32(len);

	return skb;
}
EXPORT_SYMBOL_GPL(rndis_tx_fixup);

static const struct driver_info	rndis_info = {
	.description =	"RNDIS device",
	.flags =	FLAG_ETHER | FLAG_POINTTOPOINT | FLAG_FRAMING_RN | FLAG_NO_SETINT,
	.bind =		rndis_bind,
	.unbind =	rndis_unbind,
	.status =	rndis_status,
	.rx_fixup =	rndis_rx_fixup,
	.tx_fixup =	rndis_tx_fixup,
};

static const struct usb_device_id products[] = {
	{
		/* Wireless / RNDIS (class e0, sub 01, proto 03) */
		USB_INTERFACE_INFO(USB_CLASS_WIRELESS_CONTROLLER, 1, 3),
		.driver_info = (unsigned long) &rndis_info,
	},
	{
		/* Comm / RNDIS (class 02, sub 02, proto ff) */
		USB_INTERFACE_INFO(USB_CLASS_COMM, 2, 0xff),
		.driver_info = (unsigned long) &rndis_info,
	},
	{
		/* Specific VID:PID for Marvell 81332FT */
		USB_DEVICE_AND_INTERFACE_INFO(0x13d3, 0x3487, USB_CLASS_WIRELESS_CONTROLLER, 1, 3),
		.driver_info = (unsigned long) &rndis_info,
	},
	{ },
};
MODULE_DEVICE_TABLE(usb, products);

static struct usb_driver rndis_driver = {
	.name = "rndis_host2",
	.id_table =	products,
	.probe =	usbnet_probe,
	.disconnect =	usbnet_disconnect,
	.suspend =	usbnet_suspend,
	.resume =	usbnet_resume,
	.reset_resume =	usbnet_resume,
	.supports_autosuspend = 1,
	.disable_hub_initiated_lpm = 1,
};

module_usb_driver(rndis_driver);

MODULE_AUTHOR("David Brownell / F515 team");
MODULE_DESCRIPTION("Host Side support for RNDIS Networking Links (F515 tailored)");
MODULE_LICENSE("GPL");
