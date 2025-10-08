package app

import "core:net"
import "core:fmt"
import "core:mem"
import "core:encoding/uuid"
import "core:crypto"

CURRENT_NET_VERSION :u32: 2

NetAction :: enum u32 {
    SERVER_ACK,
    GAME_STATE,
    ENTITY_LOAD,
    ENTITY_MOVE,
    ENTITY_LIFETIME,
    ASSIGN_PLAYER,
    ENTITY_BEHAVIOUR
}

NetData :: struct {
    /* HEADER */
    version: u32,
    action: NetAction,
    size: u32,
    require_ack: bool,

    /* DATA */
    frame: NetUnion
}

NetUnion :: union {
    ServerAck,
    EntityMove,
    GameState,
    Entity,
    EntityLifetime,
    AssignPlayer,
    NetEntityBehaviour,
    Ack
}

Ack :: struct {
    id: uuid.Identifier
}

ServerAck :: struct {
    endpoint: net.Endpoint
}

EntityMove :: struct {
    id: i32,
    x: f32,
    y: f32
}

EntityLifetime :: struct {
    id: i32,
    lifetime: Lifetime
}

NetEntityBehaviour :: struct {
    id: i32,
    behaviour: EntityBehaviour
}

AssignPlayer :: i32

SendQueue :: struct {
    id: uuid.Identifier,
    sock: net.UDP_Socket,
    endpoint: net.Endpoint,
    action: NetAction,
    data: []u8,
    require_ack: bool,
    next_check: f32 // seconds
}

init_udp_server :: proc(ip_addr: string, port: int) -> (net.UDP_Socket, bool) {
    local_addr, ok := net.parse_ip4_address(ip_addr)

    if !ok {
        fmt.println("Failed to parse IP")
        return net.UDP_Socket{}, false
    }

    endpoint := net.Endpoint {
        address = local_addr,
        port = port
    }
    sock, err := net.make_bound_udp_socket(local_addr, port)
    if err != nil {
        fmt.println("Failed to listen to UDP")
        return net.UDP_Socket{}, false
    }
    fmt.printfln("Listening on UDP: %s", net.endpoint_to_string(endpoint))

    err = net.set_blocking(sock, false)
    if err != nil {
        fmt.println("Failed to set non-blocking:", err)
        return net.UDP_Socket{}, false
    }

    fmt.printfln("Server listening on %s:%d", ip_addr, port)
    return sock, true
}


recv_ack :: proc() {
    // if already_received {
    //     ignore
    // }
}


// sends a struct and keeps sending until an ACK is received
queue_struct_ack :: proc(sock: net.UDP_Socket, endpoint: net.Endpoint, action: NetAction, data: $T, queue: ^[dynamic]SendQueue) -> bool {
    context.random_generator = crypto.random_generator()
    random_uuid = uuid.generate_v7()
    append(queue, SendQueue{random_uuid, sock, endpoint, action, data, 0})
}

run_ack_queue :: proc(queue: ^[dynamic]SendQueue, time_diff: f32) {
    for &q in queue {
        q.next_check -= time_diff
        if q.next_check <= 0 {
            send_struct(q.sock, q.endpoint, q.action, q.data, true)
            q.next_check = 0.1
        }
    }
}

ack_from_queue :: proc(id: uuid.Identifier, queue: ^[dynamic]SendQueue) {
    for &q, index in queue {
        if q.id == id {
            unordered_remove(queue, index)
            return
        }
    }
}

send_struct :: proc(sock: net.UDP_Socket, endpoint: net.Endpoint, action: NetAction, data: $T, require_ack := false) -> bool {
    // fmt.printfln("Sending to : %f:%d", endpoint.address.(net.IP4_Address), endpoint.port)
    buffer: [256]u8
    t_size :u32= size_of(T)

    // Write header (u32 each)
    bytes: [4]u8
    index :u32= 0
    bytes = transmute([4]u8)CURRENT_NET_VERSION
    mem.copy(&buffer[index], &bytes, 4)
    index += 4
    bytes = transmute([4]u8)u32(action)
    mem.copy(&buffer[index], &bytes, 4)
    index += 4
    bytes = transmute([4]u8)t_size
    mem.copy(&buffer[index], &bytes, 4)
    index += 4
    bytes = transmute([4]u8)u32(require_ack)
    mem.copy(&buffer[index], &bytes, 4)
    index += 1

    frame_bytes :[]u8= mem.any_to_bytes(data)
    mem.copy(&buffer[index], &frame_bytes[0], int(t_size))
    _, err := net.send_udp(sock, buffer[:index+t_size], endpoint)
    return err == nil
}

recv_struct :: proc(sock: net.UDP_Socket) -> (NetData, net.Endpoint, bool) {
    buf: [256]u8

    n, endpoint, err := net.recv_udp(sock, buf[:256])
    if err != nil {
        if err != .Would_Block {
            fmt.printfln("[!] recv:: network error :: %s", err)
        }
        return {}, {}, false
    }

    if n == 0 {
        // fmt.println("[!] recv:: NO DATA")
        return {}, endpoint, false
    }

    index :u32= 0
    version     := (transmute(^u32)(&buf[index]))^
    index += 4
    action_u32  := (transmute(^u32)(&buf[index]))^
    index += 4
    action      := NetAction(action_u32)
    t_size      := (transmute(^u32)(&buf[index]))^
    index += 4
    require_ack := (transmute(^bool)(&buf[index]))^
    index += 1

    frame :[]u8= buf[index:index+t_size]

    if(len(frame) == 0)
    {
        fmt.println("[!] recv: frame length is 0")
        return {}, endpoint, false
    }

    net_union: NetUnion
    switch action {
        case .SERVER_ACK:
            fmt.printfln("[NT_CBCK] ACK received")
            net_union = ServerAck{endpoint}
        case .GAME_STATE:
            game_state := transmute(^GameState)(&frame[0])
            fmt.printfln("[NT_CBCK] game_state: %d", u32(game_state^))
            net_union = game_state^
        case .ENTITY_LOAD:
            e := transmute(^Entity)(&frame[0])
            fmt.printfln("[NT_CBCK] eload: %d, %f, %f,", e.id, e.pos.x, e.pos.y)
            net_union = e^
        case .ENTITY_MOVE:
            emove := transmute(^EntityMove)(&frame[0])
            // log.debugf("[NT_CBCK] emove: %d: (%f, %f)", emove.id, emove.x, emove.y)
            net_union = emove^
        case .ENTITY_LIFETIME:
            elifetime := transmute(^EntityLifetime)(&frame[0])
            // log.debugf("[NT_CBCK] elifetime: %d: (%f, %f)", elifetime.id, elifetime.lifetime)
            net_union = elifetime^
        case .ASSIGN_PLAYER:
            net_union = (transmute(^AssignPlayer)(&frame[0]))^
        case .ENTITY_BEHAVIOUR:
            net_union = (transmute(^NetEntityBehaviour)(&frame[0]))^
    }

    return NetData{version, action, t_size, require_ack, net_union}, endpoint, true
}