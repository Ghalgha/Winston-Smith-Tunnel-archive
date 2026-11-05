#[cfg(test)]
use crate::turn_core::{AF_IPV4, NativeAddress};
use crate::{
    dns,
    packet::{PACKET_CAPACITY, PACKET_HEADROOM, PacketBuf, PacketPool},
    spsc_ring::{self, SpscReceiver, SpscSender, TrySendError},
    turn_core::{
        EVENT_CHANNEL_BOUND, EVENT_CHANNEL_REBIND_EXHAUSTED, EVENT_CONTROL_OVERFLOW,
        EVENT_EVENT_OVERFLOW, EVENT_FORCED_DESTROY, EVENT_RELAY_ADDRESS, EVENT_REQUEST_COMPLETE,
        EVENT_STATE, EVENT_STUN_RESPONSE_ERROR, METHOD_ALLOCATE, METHOD_CHANNEL_BIND,
        METHOD_CREATE_PERMISSION, METHOD_REFRESH, NativeCore, RESULT_AUTHENTICATION,
        RESULT_PROTOCOL, RESULT_TIMEOUT, STATE_DEALLOCATED, STATE_DESTROYING, STATE_READY,
        TurnControlTransport, native_status_text,
    },
    turn_endpoint::{TurnEndpoint, TurnTransportMode, TurnWireTransport, resolve_turn_endpoints},
    turn_stream::{
        self, TurnStreamFrame, TurnStreamReader, TurnStreamWriteFailure, TurnStreamWriter,
    },
};
use anyhow::{Context, Result, anyhow, bail};
use crossbeam_queue::ArrayQueue;
use socket2::SockRef;
use std::{
    net::SocketAddr,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU16, AtomicU64, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::{
    net::UdpSocket,
    sync::{Notify, OwnedSemaphorePermit, Semaphore, watch},
    task::JoinHandle,
};