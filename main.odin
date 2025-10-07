/*

CONCEPT

- tower defense
- multiplayer
- only shapes -> no art assets -> but maybe some shaders

- players are in the game, have health and need to run around and repair/build/fight
-> players must be within a distance to affect things



TODO:

1. make some NetAction, require ACK


*/

package app

import rl "vendor:raylib"
import b2 "vendor:box2d"
import "core:os"
import "core:fmt"
import "core:thread"
import "core:math"
import "core:strings"
import "core:unicode/utf8"
import "core:slice"
import "core:mem"
import "core:net"
import "core:encoding/cbor"
import "core:encoding/uuid"
import "rlmu" // from: https://gist.github.com/keenanwoodall/b6f7ecf6346ba3be4842c7d9fd1f372d
import mu "vendor:microui"

SPAWN_TIMER_TIME :f32: 2

PORT :: 65439

PLAYER_ZONE :: rl.Rectangle{0, 0, 1000, 1000}

PLAYER_SPAWN_POINT :: rl.Vector2{500, 500}

LOCALHOST :: "127.0.0.1"

explosion_sound: rl.Sound

normalize_vector :: proc(v: rl.Vector2) -> rl.Vector2 {
    return v / math.sqrt(v.x*v.x + v.y*v.y)
}

zone_limit := true

PROJECTILE_SPEED :f32: 4

ip4_input_text := make_slice([]u8, 128)
ip4_input_text_len : int

explosion_texture_path :cstring= "assets/bk_explo_one.png"
explosion_texture : rl.Texture2D
explosion_texture_frames: u32
EXPLOSION_FRAME_DELAY :f32: 0.02

cstring_to_string :: proc(b: []u8) -> string {
    n := 0
    for n < len(b) && b[n] != 0 {
        n += 1
    }
    return string(b[:n])
}

editor_entities := []Entity{
    Entity{0, {250, 250}, {}, rl.RED, .PLAYER, Circle{25}, true, 10, .PLAYER},
    Entity{0, {800, 400}, {}, rl.GREEN, ZombieAttack{0, false}, Circle{25}, true, 1, .ENEMY/*, 0, 0*/},
    Entity{0, {400, 400}, {}, rl.MAGENTA, LookAndShoot{1, 0, false}, Circle{25}, true, 1, .ENEMY},
    Entity{0, {}, {}, rl.GREEN, MiningResource{}, Diamond{{90, 90}}, true, 1, .NONE},
    Entity{0, {}, {}, rl.BLUE, PickupResource{}, Diamond{{8, 8}}, true, 1, .NONE},
    Entity{0, {}, {}, rl.PINK, DefensePoint{}, Rectangle{{100, 100}}, true, 10, .NONE},
    Entity{0, {}, {}, rl.Color{241, 244, 191, 255}, EnemySpawner{}, Circle{80}, true, 10, .NONE},
}

Game :: struct {
    b2world: b2.WorldId,
    hosting: Hosting,
    sock: net.UDP_Socket,
    state: GameState,
    self: i32,
    mode: GameMode,
    entities: [dynamic]Entity,
    console_command_history: [dynamic]string,
    console_command: string,
    is_console_open: bool,
    editor_selected_entity: u32,
    is_editor_entity_selected: bool,
    resources: u32,
    server_endpoint: net.Endpoint,
    server_endpoint_established: bool,
    server_endpoint_ack_timeout: f32,
    clients: [dynamic]ClientRef,
    send_queue: [dynamic]SendQueue
}

ClientRef :: struct {
    endpoint: net.Endpoint,
    id: i32
}

Hosting :: enum {
    SINGLE,
    SERVER,
    CLIENT
}

GameState :: enum(u32) {
    MAIN_MENU,
    LOADING,
    PLAYING
}

GameMode :: enum(u32) {
    NORMAL,
    EDITOR
}

Entity :: struct {
    id: i32,
    pos: rl.Vector2,
    vel: rl.Vector2,
    color: rl.Color,
    behaviour: EntityBehaviour,
    shape: Shape,
    lifetime: Lifetime,
    health: u32,
    faction: Faction/*,
    body_id: b2.BodyId,
    shape_id: b2.ShapeId*/
}

Faction :: enum(u32) {
    NONE,
    PLAYER,
    ENEMY
}

Lifetime :: union {
    bool,
    f32
}

EntityBehaviour :: union {
    EBType,
    LookAndShoot,
    DeathAnimation,
    ZombieAttack,
    MiningResource,
    PickupResource,
    DefensePoint,
    EnemySpawner
    // Gate,
    // SpawnPoint
}

EBType :: enum {
    PLAYER,
    STATIC_BODY,
    DYNAMIC_BODY,
}

LookAndShoot :: struct {
    rotation: f32,
    target_id: i32,
    has_target: bool
}

DeathAnimation :: struct {
    pos: rl.Vector2,
    frame: u32,
    next_frame_countdown: f32
}

ZombieAttack :: struct {
    target_id: i32,
    has_target: bool
}

PickupResource :: struct {
}

MiningResource :: struct {
}

EnemySpawner :: struct{
    spawn_timer: f32
}

DefensePoint :: struct {

}

Shape :: union {
    Rectangle,
    Circle,
    Diamond
}

Rectangle :: struct {
    size: rl.Vector2
}

Circle :: struct {
    radius: f32
}

Diamond :: struct {
    size: rl.Vector2
}

get_entity :: proc(game: ^Game, id: i32) -> (^Entity, bool) {
    for &e in game.entities {
        if e.id == id do return &e, true
    }

    return {}, false
}

save_to_file :: proc(filepath: string, game: ^Game) {
    file, err := os.open(filepath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC)
    if err != os.ERROR_NONE {
        // return false
    }
    defer os.close(file)

    for e in game.entities{
        bytes := mem.any_to_bytes(e)
        l :u32= u32(len(bytes))
        len_bytes := transmute([4]u8)l

        _, werr := os.write(file, len_bytes[:])
        _, wwerr := os.write(file, bytes)
        // return werr == os.ERROR_NONE
    }
}

load_from_file :: proc(filepath: string, game: ^Game) {
    data, ok := os.read_entire_file(filepath, context.allocator)
    if !ok {
        fmt.println("Error reading file")
    }
    defer delete(data, context.allocator)

    i :int=0
    for {
        if(i >= len(data)) do break
        if(i+4 >= len(data)) do break

        slice :[4]u8 = slice.to_type(data[i:i+4], [4]u8)
        i+=4
        l := transmute(u32)slice
        fmt.printfln("loading len: %d", l)

        if(i >= len(data)) do break
        if(i+int(l) >= len(data)) do break
        buffer := data[i:i+int(l)]
        e := transmute(^Entity)&buffer[0]
        append(&game.entities, e^)
        i += int(l)
    }

    game.self = 0 // TODO: load the whole game state and entities
}

editor_input :: proc(game: ^Game, camera: rl.Camera2D) {
    if rl.IsKeyPressed(.ONE) { // PLAYER
        game.editor_selected_entity = 0
        game.is_editor_entity_selected = true
    }
    if rl.IsKeyPressed(.TWO) { // Zombie
        game.editor_selected_entity = 1
        game.is_editor_entity_selected = true
    }
    if rl.IsKeyPressed(.THREE) { // LookAndShoot
        game.editor_selected_entity = 2
        game.is_editor_entity_selected = true
    }
    if rl.IsKeyPressed(.FOUR) { // resource
        game.editor_selected_entity = 3
        game.is_editor_entity_selected = true
    }
    if rl.IsKeyPressed(.FIVE) { // defense point
        game.editor_selected_entity = 5
        game.is_editor_entity_selected = true
    }
    if rl.IsKeyPressed(.SIX) { // Enemy Spawner
        game.editor_selected_entity = 6
        game.is_editor_entity_selected = true
    }

    if game.is_editor_entity_selected  {
        // display ghost entity under cursor
        pos := rl.GetMousePosition()
        pos = rl.GetScreenToWorld2D(pos, camera)

        entity := editor_entities[game.editor_selected_entity]
        entity.pos = snap_to_grid(pos)
        draw_entity(game, &entity, 80)

        // on click place entity
        if rl.IsMouseButtonPressed(.LEFT) {
            game.is_editor_entity_selected = false
            
            id := i32(len(game.entities))
            entity.id = id
            append(&game.entities, entity)
            if game.editor_selected_entity == 0 {
                game.self = id
            }
        }
    }
}

snap_to_grid :: proc(pos: rl.Vector2) -> rl.Vector2 {
    p := rl.Vector2{
        pos.x - f32(u32(pos.x) % 50),
        pos.y - f32(u32(pos.y) % 50)
    }

    return p
}

get_user_input :: proc(game: ^Game, camera: ^rl.Camera2D) {
    move := rl.Vector2{}
    if rl.IsKeyDown(.W) {
        move.y -= 1
    }
    if rl.IsKeyDown(.S) {
        move.y += 1
    }
    if rl.IsKeyDown(.A) {
        move.x -= 1
    }
    if rl.IsKeyDown(.D) {
        move.x += 1
    }

    // shoot projectile
    if rl.IsMouseButtonPressed(.LEFT) {
        origin_e, ok := get_entity(game, game.self)
        origin := origin_e.pos
        mouse_pos := rl.GetMousePosition()
        mouse_pos = rl.GetScreenToWorld2D(mouse_pos, camera^)
        // fmt.println(mouse_pos)
        dir := mouse_pos - origin
        magnitude := math.sqrt_f32(dir.x*dir.x + dir.y*dir.y)
        dir = dir / magnitude
        e := Entity{i32(len(game.entities)), origin, dir * PROJECTILE_SPEED, rl.YELLOW, .DYNAMIC_BODY, Circle{5}, 2.0, 0, .PLAYER/*, 0, 0*/}
        append(&game.entities, e)

        if game.hosting == .SERVER {
            broadcast_update(game, .ENTITY_LOAD, e)
        }
        else if game.hosting == .CLIENT {
            send_struct(game.sock, game.server_endpoint, .ENTITY_LOAD, e, true)
        }
    }

    move = move * rl.GetFrameTime() * 400
    e, ok := get_entity(game, game.self)
    if zone_limit {
        move = limit_player_to_zone(e, move)
    }

    new_pos := e.pos + move
    e.pos = new_pos

    if move != {} && game.hosting == .SERVER {
        broadcast_update(game, .ENTITY_MOVE, EntityMove{game.self, new_pos.x, new_pos.y})
    }
    else if move != {} && game.hosting == .CLIENT {
        send_struct(game.sock, game.server_endpoint, .ENTITY_MOVE, EntityMove{game.self, new_pos.x, new_pos.y})
    }
}

draw_entity :: proc(game: ^Game, e: ^Entity, alpha: u8 = 255) {
    switch b in e.behaviour {
        case EBType:
            switch b {
                case .STATIC_BODY: // ignore
                case .PLAYER:      // ignore
                case .DYNAMIC_BODY:
            }
        case LookAndShoot:
            // look and shoot
            {
                draw_point: rl.Vector2
                if(b.has_target) {
                    that, ok := get_entity(game, b.target_id)
                    draw_point = that.pos
                }
                else {
                    cos := math.cos_f32(b.rotation)
                    sin := math.sin_f32(b.rotation)
                    p := rl.Vector2{0, 200}
                    draw_point = e.pos + rl.Vector2{ p.x*cos - p.y*sin, p.x*sin + p.y*cos }// TODO: TEST: make a rotation matrix and use that natively in odin
                }

                rl.DrawLineV(e.pos, draw_point, rl.Color{125, 255, 125, 255})
            }
        case DeathAnimation:
            {
                width: f32
                height: f32
                switch &s in e.shape {
                    case Rectangle:
                        width = s.size.x
                        height = s.size.y
                    case Circle:
                        width = s.radius
                        height = s.radius
                    case Diamond:
                        width = s.size.x
                        height = s.size.y
                }
                rl.DrawTexturePro(explosion_texture, {f32(b.frame*64), 0, 64, 64}, {b.pos.x - 64/2*3, b.pos.y - 64/2*3, 64*3, 64*3}, {0, 0}, 0, rl.WHITE)
                return
            }
        case ZombieAttack:
            {
                draw_point: rl.Vector2
                if(b.has_target) {
                    that, ok := get_entity(game, b.target_id)
                    draw_point = that.pos
                }
                else {
                    draw_point = e.pos + rl.Vector2{0, 100}
                }

                rl.DrawLineV(e.pos, draw_point, rl.Color{125, 0, 125, 255})
            }
        case MiningResource:
            // nothing
        case PickupResource:
            // nothing
        case DefensePoint:
            // nothing
        case EnemySpawner:
            rl.DrawCircleV(e.pos, 35, rl.Color{241, 244, 191, 255})
    }

    color := e.color
    color.a = alpha
    switch &s in e.shape {
        case Rectangle:
            rl.DrawRectangleV(e.pos, s.size, color)
        case Circle:
            rl.DrawCircleV(e.pos, s.radius, color)
        case Diamond:
            rect := rl.Rectangle{e.pos.x, e.pos.y, s.size.x, s.size.y}
            origin := rl.Vector2{s.size.x/2, s.size.y/2}
            rl.DrawRectangleV(e.pos, s.size, color)
            // rl.DrawRectanglePro(rect, origin, rl.DEG2RAD * 45, color)
    }
}

create_pickup_resource :: proc(game: ^Game, pos: rl.Vector2) -> Entity {
    pickup := editor_entities[4]
    pickup.pos = pos
    pickup.id = i32(len(game.entities))

    append(&game.entities, pickup)

    return pickup
}

collect_pickup_resource :: proc(game: ^Game) {
    game.resources += 1
}

draw_player_border :: proc() {
    rl.DrawLineEx({0, 0}, {1000, 0}, 5, rl.Color{255, 50, 50, 255})
    rl.DrawLineEx({1000, 0}, {1000, 1000}, 5, rl.Color{255, 50, 50, 255})
    rl.DrawLineEx({1000, 1000}, {0, 1000}, 5, rl.Color{255, 50, 50, 255})
    rl.DrawLineEx({0, 1000}, {0, 0}, 5, rl.Color{255, 50, 50, 255})
}

broadcast_update :: proc(game: ^Game, action: NetAction, data: $T) {
    for &c in game.clients {
        send_struct(game.sock, c.endpoint, action, data)
    }
}

run_entity :: proc(game: ^Game, e: ^Entity) {
    active := true
    switch &l in e.lifetime  {
        case bool:
            active = l
        case f32:
            l -= rl.GetFrameTime()
            if l <= 0 {
                e.lifetime = false
                return
            }
    }

    switch &b in e.behaviour {
        case EBType:
            if game.hosting == .CLIENT do return
            if !active do return
            switch b {
                case .STATIC_BODY: // ignore
                case .PLAYER:
                case .DYNAMIC_BODY:
                    e.pos += e.vel * rl.GetFrameTime() * 8 * 80

                    broadcast_update(game, .ENTITY_MOVE, EntityMove{e.id, e.pos.x, e.pos.y})

                    for &that in game.entities {
                        switch &that_shape in that.shape{
                            case Diamond:
                                switch &behave in that.behaviour {
                                    case EBType:
                                    case LookAndShoot:
                                    case DeathAnimation:
                                    case ZombieAttack:
                                    case MiningResource:
                                        {
                                            that_shape := that.shape.(Diamond)
                                            that_rect := rl.Rectangle{that.pos.x, that.pos.y, that_shape.size.x, that_shape.size.y}
                                            if rl.CheckCollisionCircleRec(e.pos, e.shape.(Circle).radius, that_rect) {
                                                pos := e.pos - e.vel * 7
                                                pickup_entity := create_pickup_resource(game, pos)
                                                broadcast_update(game, .ENTITY_LOAD, pickup_entity)
                                                e.lifetime = false
                                                broadcast_update(game, .ENTITY_LIFETIME, EntityLifetime{e.id, e.lifetime})
                                            }
                                        }
                                    case PickupResource:
                                    case DefensePoint:
                                    case EnemySpawner:
                                }
                            case Rectangle:// ignore
                            case Circle:
                            
                            switch &behave in that.behaviour {
                                case EBType:
                                case LookAndShoot:
                                case DeathAnimation:
                                    continue
                                case ZombieAttack:
                                case MiningResource:
                                    continue
                                case PickupResource:
                                    continue
                                case DefensePoint:
                                    continue
                                case EnemySpawner:
                                    continue
                            }

                            if rl.CheckCollisionCircles(e.pos, e.shape.(Circle).radius, that.pos, that.shape.(Circle).radius) {
                                if(e.faction != that.faction && that.faction != .NONE) {
                                    that.behaviour = DeathAnimation{that.pos, 0, 0}
                                    rl.PlaySound(explosion_sound)
                                    broadcast_update(game, .ENTITY_BEHAVIOUR, NetEntityBehaviour{that.id, that.behaviour})
                                    e.lifetime = false
                                    broadcast_update(game, .ENTITY_LIFETIME, EntityLifetime{e.id, e.lifetime})
                                }
                            }
                        }
                    }
            }
        case LookAndShoot:
            if !active do return
            // look and shoot
            {
                if b.has_target {
                    return
                }

                b.rotation += 1 * rl.GetFrameTime()

                cos := math.cos_f32(b.rotation)
                sin := math.sin_f32(b.rotation)
                p := rl.Vector2{0, 200}
                target_point := e.pos + rl.Vector2{ p.x*cos - p.y*sin, p.x*sin + p.y*cos }// TODO: TEST: make a rotation matrix and use that natively in odin

                if game.hosting == .CLIENT do return

                for &that in game.entities {
                    if(e.id == that.id) { 
                        continue
                    }

                    switch &s in that.shape{
                        case Rectangle:
                        case Diamond:
                        case Circle:
                            if rl.CheckCollisionCircleLine(that.pos, s.radius, e.pos, target_point) {
                                if(e.faction == that.faction || that.faction == .NONE) do continue

                                b.target_id = that.id
                                b.has_target = true
                                return
                            }
                    }

                }

                b.target_id = 0
                b.has_target = false
            }
        case DeathAnimation:
            {
                b.next_frame_countdown -= rl.GetFrameTime()
                if(b.next_frame_countdown <= 0) {
                    b.next_frame_countdown = EXPLOSION_FRAME_DELAY
                    b.frame += 1
                    if(b.frame >= explosion_texture_frames) {
                        e.lifetime = false
                    }
                }
            }
        case ZombieAttack:
            {
                if game.hosting == .CLIENT do return
                if b.has_target {
                    that, ok := get_entity(game, b.target_id)
                    e.pos += normalize_vector(that.pos - e.pos) * rl.GetFrameTime() * 20
                    broadcast_update(game, .ENTITY_MOVE, EntityMove{e.id, e.pos.x, e.pos.y})
                }
                else {
                    for &p in game.entities {
                        if p.lifetime == false do continue

                        switch &t in p.behaviour {
                            case EBType:
                            case LookAndShoot:
                            case DeathAnimation:
                            case ZombieAttack:
                            case MiningResource:
                            case PickupResource:
                            case DefensePoint:
                                b.target_id = p.id
                                b.has_target = true
                                return
                            case EnemySpawner:
                        }
                    }
                }
            }
        case MiningResource:
            // nothing
        case PickupResource:{
            // TODO: separate logic between client and server
            for &that in game.entities {
                switch &behave in that.behaviour {
                    case EBType:
                        switch behave { 
                            case .PLAYER: {
                                e_shape := e.shape.(Diamond)
                                e_rect := rl.Rectangle{e.pos.x, e.pos.y, e_shape.size.x, e_shape.size.y}
                                if rl.CheckCollisionCircleRec(that.pos, that.shape.(Circle).radius, e_rect) {
                                    e.lifetime = false
                                    collect_pickup_resource(game)
                                }
                            }
                            case .DYNAMIC_BODY:
                            case .STATIC_BODY:
                        }
                    case LookAndShoot:
                    case DeathAnimation:
                    case ZombieAttack:
                    case MiningResource:
                    case PickupResource: 
                    case DefensePoint:
                    case EnemySpawner:
                }
            }
        }
        case DefensePoint: {
            // TODO
        }
        case EnemySpawner: {
            b.spawn_timer -= rl.GetFrameTime()
            if b.spawn_timer <= 0 {
                b.spawn_timer = SPAWN_TIMER_TIME
                spawn_enemy(game, e.pos)
            }
        }
    }
}

spawn_enemy :: proc(game: ^Game, position: rl.Vector2) {
    id := i32(len(game.entities))
    new_enemy := editor_entities[1]
    new_enemy.id = id
    new_enemy.pos = position

    append(&game.entities, new_enemy)
}

// create_entity :: proc(entity_template) -> Entity {
// // TODO
// }

load_level_static :: proc(game: ^Game) {
    // body_id, shape_id := create_circle(game.b2world)
    append(&game.entities, Entity{i32(len(game.entities)), {800, 700}, {}, rl.RED, .PLAYER, Circle{25}, true, 10, .PLAYER})
    game.self = 0

    // append(&game.entities, Entity{i32(len(game.entities)), {30, 30}, {}, rl.RED, .STATIC_BODY, Rectangle{{500, 10}}, true, 0, .NONE})
    // append(&game.entities, Entity{i32(len(game.entities)), {30, 30}, {}, rl.RED, .STATIC_BODY, Rectangle{{10, 500}}, true, 0, .NONE})
    // append(&game.entities, Entity{i32(len(game.entities)), {30, 30}, {}, rl.RED, .STATIC_BODY, Rectangle{{100, 10}}, true, 0, .NONE})

    append(&game.entities, Entity{i32(len(game.entities)), {400, 400}, {}, rl.MAGENTA, LookAndShoot{1, 0, false}, Circle{25}, true, 1, .ENEMY})
    append(&game.entities, Entity{i32(len(game.entities)), {800, 400}, {}, rl.GREEN, ZombieAttack{0, false}, Circle{25}, true, 1, .ENEMY})
    append(&game.entities, Entity{i32(len(game.entities)), {800, 300}, {}, rl.GREEN, ZombieAttack{0, false}, Circle{25}, true, 1, .ENEMY})
    append(&game.entities, Entity{i32(len(game.entities)), {800, 200}, {}, rl.GREEN, ZombieAttack{0, false}, Circle{25}, true, 1, .ENEMY})

    id := i32(len(game.entities))
    spawner := editor_entities[6]
    spawner.id = id
    spawner.pos = {-100, -100}
    append(&game.entities, spawner)

    id = i32(len(game.entities))
    defense_point := editor_entities[5]
    defense_point.id = id
    defense_point.pos = {50, 800}
    append(&game.entities, defense_point)
}

create_circle :: proc (world_id: b2.WorldId, pos: b2.Vec2, origin: b2.Vec2, body_type: b2.BodyType, density :f32= 1.0) -> (b2.BodyId, b2.ShapeId) {
    body_def := b2.DefaultBodyDef()
    body_def.type = body_type
    body_def.position = pos
    body_def.rotation = b2.MakeRot(0)

    body_id := b2.CreateBody(world_id, body_def)

    shape_def := b2.DefaultShapeDef()
    shape_def.density = density

    shape := b2.MakeBox(origin.x, origin.y)
    shape_id := b2.CreatePolygonShape(body_id, shape_def, shape)
    b2.Shape_SetFriction(shape_id, 1.0)

    return body_id, shape_id
}

full_level_reset :: proc(game: ^Game, from_file: bool = false) {
    delete(game.entities)
    game.entities = make([dynamic]Entity, 0, 0)
    if from_file{
        load_from_file("game-entities.dat", game)
    }
    else {
        load_level_static(game)
    }
}

debug_commands :: proc(game: ^Game) {
    if rl.IsKeyPressed(.SLASH) {
        game.is_console_open = !game.is_console_open
    }
}

draw_console :: proc(game: ^Game) {
    xs := rl.GetScreenWidth()
    ys := rl.GetScreenHeight()

    height :i32= 50

    rl.DrawRectangle(0, ys-height, xs, height, rl.Color{80, 80, 80, 190})
    console_txt, _ := strings.clone_to_cstring(game.console_command)
    rl.DrawText(console_txt, 5, ys-height/2, height/2, rl.Color{255, 255, 255, 255})
}

get_console_input :: proc(game: ^Game) {
    if rl.IsKeyPressed(.ENTER) {
        execute_console_command(game)
        return
    }

    key := rl.GetKeyPressed()
    if transmute(u32)key > 0 do fmt.println(key)

    if key >= .A && key <= .Z {
        bytes, size := utf8.encode_rune(transmute(rune)key)
        game.console_command = strings.concatenate({game.console_command, string(bytes[:size])})
        fmt.printfln(game.console_command)
    }
    else if key == .BACKSPACE {
        str_len := len(game.console_command)
        if str_len > 0 {
            game.console_command = game.console_command[:str_len-1]
        }
    }
}

execute_console_command :: proc(game: ^Game) {
    command := game.console_command
    append(&game.console_command_history, command)

    fmt.printfln("[-CMD]: %s", command)

    if strings.equal_fold(command, "LF") {
        fmt.println("[CMD] LOAD (file)")
        full_level_reset(game, true)
    }
    else if strings.equal_fold(command, "LS") {
        fmt.println("[CMD] LOAD (static)")
        full_level_reset(game)
    }
    else if strings.equal_fold(command, "S") {
        fmt.println("[CMD] SAVE")
        save_to_file("game-entities.dat", game)
    }
    else if strings.equal_fold(command, "P") {
        fmt.println("[CMD] mode: NORMAL")
        game.mode = .NORMAL 
    }
    else if strings.equal_fold(command, "E") {
        fmt.println("[CMD] mode: EDITOR")
        game.mode = .EDITOR
    }
    else if strings.equal_fold(command, "L") {
        fmt.println("[CMD]: inverse player zone limit")
        zone_limit = !zone_limit
    }

    game.console_command = ""
    game.is_console_open = false
}

host_server :: proc(game: ^Game) {
    ok: bool
    game.hosting = .SERVER

    game.sock, ok = init_udp_server(LOCALHOST, PORT)
    if !ok {
        fmt.println("[ERR] Cannot init udp server")
        game.state = .MAIN_MENU
    }
    else {
        game.state = .LOADING
    }
}

start_client :: proc(game: ^Game, ip_addr: string) {
    game.hosting = .CLIENT

    sock, err := net.create_socket(.IP4, .UDP)
    if err != nil {
        fmt.println("[ERR] Failed to bind socket")
        return
    }
    game.sock = sock.(net.UDP_Socket)
    err2 := net.set_blocking(game.sock, false)
    if err2 != nil {
        fmt.println("Failed to set non-blocking:", err)
        return
    }
    addr, ok2 := net.parse_ip4_address(ip_addr)
    if !ok2 {
        fmt.printfln("[ERR] Cannot parse ip4 addr: %s", ip_addr)
        game.state = .MAIN_MENU
        return
    }

    game.server_endpoint = net.Endpoint{addr, PORT}
    game.state = .LOADING
}

limit_player_to_zone :: proc(e: ^Entity, delta_p: rl.Vector2) -> rl.Vector2 {
    new_pos := e.pos + delta_p

    ret_delta_p := delta_p

    if new_pos.x >= PLAYER_ZONE.x + PLAYER_ZONE.width do ret_delta_p.x = 0
    if new_pos.x <= PLAYER_ZONE.x do ret_delta_p.x = 0
    if new_pos.y >= PLAYER_ZONE.y + PLAYER_ZONE.height do ret_delta_p.y = 0
    if new_pos.y <= PLAYER_ZONE.y do ret_delta_p.y = 0

    return ret_delta_p
}

handle_recv :: proc(game: ^Game) -> bool {
    for {
        frame, endpoint, ok := recv_struct(game.sock)

        if !ok {
            // ignore, maybe no data, maybe error
            return false
        }

        // fmt.printfln("received: %d bytes", size_of(frame.frame))

        switch game.hosting{
            case .SINGLE:
            case .CLIENT: {
                if endpoint != game.server_endpoint {
                    fmt.println("[ERR] Received from wrong endpoint")
                    return false
                }
            }
            case .SERVER:
                // TODO: re-send to all other clients
        }


        handle_net_recv(frame, game)
    }

    return true
}

send_init_ack :: proc(game: ^Game) {
    ok := send_struct(game.sock, game.server_endpoint, .SERVER_ACK, 1)
    if ok {
        fmt.println("[ACK] sent")
    }
    else {
        fmt.println("[ERR] ACK failed")
    }
}

send_game_state_to_client :: proc(game: ^Game, client: net.Endpoint) {
    // create new player for client
    id := i32(len(game.entities))
    new_player := editor_entities[0]
    new_player.id = id
    append(&game.entities, new_player)

    // send all entities to player
    for &e in game.entities {
        send_struct(game.sock, client, .ENTITY_LOAD, e, true)
    }

    // assign player to client
    send_struct(game.sock, client, .ASSIGN_PLAYER, new_player.id, true)

    // set state = .PLAYING
    send_struct(game.sock, client, .GAME_STATE, GameState.PLAYING, true)
}

main :: proc() {
    game := Game{{}, .SINGLE, 0, .MAIN_MENU, -1, .NORMAL, make([dynamic]Entity, 0, 0), make([dynamic]string, 0, 0), "", false, 0, false, 0, {}, false, 0, make([dynamic]ClientRef, 0, 0), make([dynamic]SendQueue, 0, 0)}

    rl.SetConfigFlags({rl.ConfigFlag.WINDOW_RESIZABLE})
    rl.InitWindow(1280, 720, "Top Down Shooter")
    defer rl.CloseWindow()

    if len(os.args) > 1 {
        switch os.args[1] {
            case "s":
                host_server(&game)
                rl.SetWindowPosition(10, 10)
            case "c":
                start_client(&game, LOCALHOST)
                rl.SetWindowPosition(10, 720 + 10*2)
            case:
                fmt.printfln("Command '%s' cannot be found. Crashing out!", os.args[1])
        }
    }

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    explosion_sound = rl.LoadSound("assets/explosion.mp3")
    defer rl.UnloadSound(explosion_sound)

    rl.SetTargetFPS(122)

    explosion_texture = rl.LoadTexture(explosion_texture_path)
    explosion_texture_frames = u32(explosion_texture.width / 64)

    /*** CAMERA ***/
    camera := rl.Camera2D{}
    camera.offset = {1280/2, 720/2}
    camera.zoom = 0.5

    /*** BOX2D Setup ***/
    LENGTH_UNITS_PER_METER :: 256
    b2.SetLengthUnitsPerMeter(LENGTH_UNITS_PER_METER)

    world_def := b2.DefaultWorldDef()

    // world_def.gravity.y = LENGTH_UNITS_PER_METER * 9.80665
    game.b2world = b2.CreateWorld(world_def)
    defer b2.DestroyWorld(game.b2world)

    mctx := rlmu.init_scope()

    /*** Main Loop ***/
    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        defer rl.EndDrawing()
        rl.ClearBackground(rl.BLACK)

        debug_commands(&game)

        switch game.state {
            case .MAIN_MENU:
                rlmu.begin_scope()
                
                if mu.begin_window(mctx, "Test Window", { 100, 100, 500, 500 }) {
                    defer mu.end_window(mctx)
                    
                    mu.layout_row(mctx, { 90, -1 }, 0)
                    mu.label(mctx, "ip4add: ")
                    if .SUBMIT in mu.textbox(mctx, ip4_input_text, &ip4_input_text_len) {
                        mu.set_focus(mctx, mctx.last_id)
                    }

                    mu.layout_row(mctx, { 90, 90, 150 }, 0)
                    if .SUBMIT in mu.button(mctx, "HOST") {
                        host_server(&game)
                    }
                    if .SUBMIT in mu.button(mctx, "CONNECT") {
                        start_client(&game, LOCALHOST)//cstring_to_string(ip4_input_text))
                    }
                    if .SUBMIT in mu.button(mctx, "SINGLE PLAYER") {
                        game.hosting = .SINGLE
                        game.state = .LOADING
                    }
                }
            case .LOADING:
                {
                    font_size :i32= 50
                    x := rl.GetScreenWidth() / 2 - (12*font_size) / 4
                    y := rl.GetScreenHeight() / 2
                    rl.DrawText("...LOADING...", x, y, font_size, rl.WHITE)

                    if game.hosting == .CLIENT {
                        if !game.server_endpoint_established { // establish "connection" to server
                            game.server_endpoint_ack_timeout -= rl.GetFrameTime()
                            if game.server_endpoint_ack_timeout < 0 {
                                game.server_endpoint_ack_timeout = 2
                                send_init_ack(&game)
                            }
                        }
                        ok := handle_recv(&game)
                        if ok do game.server_endpoint_ack_timeout = 2
                    }
                    else {
                        // load_from_file("game-entities.dat", &game)
                        load_level_static(&game)
                        game.state = .PLAYING
                    }
                }
            case .PLAYING:
                {
                    rl.BeginMode2D(camera)

                    draw_player_border()

                    if game.hosting == .CLIENT || game.hosting == .SERVER {
                        handle_recv(&game)
                        run_ack_queue(&game.send_queue, rl.GetFrameTime())
                    }

                    if game.self >= 0 {
                        player, ok := get_entity(&game, game.self)
                        player_pos := player.pos
                        camera.target = player_pos// + {20, 20}

                        // camera.zoom = math.exp_f32(math.log2_f32(camera.zoom) + f32(rl.GetMouseWheelMove()*0.1));
                    }

                    run_e := true
                    switch game.mode {
                        case .NORMAL:
                            if game.self >= 0 && !game.is_console_open {
                                get_user_input(&game, &camera)
                            }
                        case .EDITOR:
                            run_e = false
                            {
                                editor_input(&game, camera)
                            }
                    }

                    for &e in game.entities {
                        switch &l in e.lifetime  {
                            case bool:
                                if l == false do continue
                            case f32:
                                // intentionally empty
                        }

                        draw_entity(&game, &e)

                        if run_e {
                            run_entity(&game, &e)
                        }
                    }

                    rl.EndMode2D()
                    if game.is_console_open {
                        draw_console(&game)
                        get_console_input(&game)
                    }
                }
        }

        switch game.mode {
            case .NORMAL:
                // intentionally ignored
            case .EDITOR:
                x := rl.GetScreenWidth() - 300
                y := rl.GetScreenHeight() - 50
                rl.DrawText("EDITOR", x, y, 30, rl.Color{125, 255, 125, 255})
        }

        {// UI
            screen_width := rl.GetScreenWidth()
            screen_height := rl.GetScreenHeight()

            rl.DrawRectangleV({0, 0}, {200, 50}, rl.GRAY)
            rl.DrawText(rl.TextFormat("Resources: %d", game.resources), 5, 5, 25, rl.WHITE)

            if game.hosting == .CLIENT {
                rl.DrawText("CLIENT", 10, screen_height - 30, 30, rl.Color{20, 255, 20, 255})
            }
            if game.hosting == .SERVER {
                rl.DrawText("SERVER", 10, screen_height - 30, 30, rl.Color{20, 255, 20, 255})
            }

            if !zone_limit {
                rl.DrawText("NO ZONE LIMIT", screen_width - 100, screen_height - 30, 30, rl.Color{255, 20, 20, 255})
            }
        }

    }
}


handle_net_recv :: proc(net_data: NetData, game: ^Game) {
    // if game.hosting == .CLIENT {
    //     return
    // }

    switch &f in net_data.frame {
        case ServerAck:
            if game.hosting == .SERVER {
                append(&game.clients, ClientRef{f.endpoint, i32(len(game.entities))})
                send_game_state_to_client(game, f.endpoint)
            }
        case GameState:
            if game.hosting == .CLIENT {
                game.state = f
            }
        case Entity:
            {
                append(&game.entities, f)
            }
        case EntityMove:

            e, ok := get_entity(game, f.id)

            if !ok {
                // fmt.printfln("Entity with id '%d' does not exist", f.id)
                return
            }

            if game.hosting == .CLIENT && game.state == .PLAYING {
                e.pos.x = f.x
                e.pos.y = f.y
            }
            else if game.hosting == .SERVER && game.state == .PLAYING {
                // TODO: check that sockets are same ID as player ID
                e.pos.x = f.x
                e.pos.y = f.y
            }
        case EntityLifetime:
            if game.hosting == .CLIENT && game.state == .PLAYING {
                e, ok := get_entity(game, f.id)

                if !ok {
                    fmt.printfln("Entity with id '%d' does not exist", f.id)
                    return
                }

                e.lifetime = f.lifetime
            }
        case AssignPlayer:
            if game.hosting == .CLIENT {
                game.self = f
            }
        case NetEntityBehaviour:
            if game.hosting == .CLIENT {
                e, ok := get_entity(game, f.id)

                if !ok {
                    fmt.printfln("Entity with id '%d' does not exist", f.id)
                    return
                }

                e.behaviour = f.behaviour
                switch &b in e.behaviour {
                    case EBType:
                    case LookAndShoot:
                    case DeathAnimation:
                        // NOTE: temporarily disabled due to testing both client and server on same PC
                        // rl.PlaySound(explosion_sound)
                    case ZombieAttack:
                    case MiningResource:
                    case PickupResource:
                    case DefensePoint:
                    case EnemySpawner:
                }
            }
        case Ack:
            ack_from_queue(f.id, &game.send_queue)
    }
}