#include "room_geometry.h"

#include <algorithm>
#include <cmath>

namespace sr {
namespace {

constexpr float kNudge = 0.006f;   // how far outside its wall a corner sits, so a route can run along the wall's face
constexpr float kShrink = 0.002f;  // how much smaller a wall is when testing a route against it (less than kNudge,
                                   // so a corner pressed against another wall counts as buried in it)
constexpr float kFar = 1e9f;

float lengthOf(float x, float z) { return std::sqrt(x * x + z * z); }

}  // namespace

void RoomGeometry::setRoom(float width, float depth, float ceiling, const std::vector<Wall>& walls) {
    ceiling_ = ceiling;
    boxes_.clear();
    corners_.clear();
    for (const Wall& w : walls) {
        if (int(boxes_.size()) >= kMaxWalls) break;
        Box box;
        box.centre = {(w.ax + w.bx) * 0.5f, (w.az + w.bz) * 0.5f};
        const float run = lengthOf(w.bx - w.ax, w.bz - w.az);
        box.along = run > 1e-5f ? Flat{(w.bx - w.ax) / run, (w.bz - w.az) / run} : Flat{1.0f, 0.0f};
        box.half_thickness = std::max(w.thickness, 0.02f) * 0.5f;
        box.half_length = run * 0.5f + box.half_thickness;
        box.top = std::min(w.height, ceiling);
        box.through = materialInfo(w.material).transmission;
        boxes_.push_back(box);
        for (int c = 0; c < 4; ++c) {  // in order round the wall, so neighbours in the list share a face
            const float u = (c == 0 || c == 3 ? -1.0f : 1.0f) * (box.half_length + kNudge);
            const float v = (c < 2 ? -1.0f : 1.0f) * (box.half_thickness + kNudge);
            corners_.push_back({box.centre.x + box.along.x * u - box.along.z * v, box.centre.z + box.along.z * u + box.along.x * v});
        }
    }
    const size_t n = corners_.size();
    usable_.assign(n, 1);
    for (size_t i = 0; i < n; ++i) {
        float enter, leave;
        if (std::fabs(corners_[i].x) >= width * 0.5f || std::fabs(corners_[i].z) >= depth * 0.5f) usable_[i] = 0;  // outside the room
        for (const Box& box : boxes_)
            if (span(box, corners_[i], corners_[i], kShrink, enter, leave)) usable_[i] = 0;
    }
    visible_.assign(n * n, 0);
    for (size_t i = 0; i < n; ++i)
        for (size_t j = i + 1; j < n; ++j)
            if (usable_[i] && usable_[j] && !crossesAny(corners_[i], corners_[j])) visible_[i * n + j] = visible_[j * n + i] = 1;
}

bool RoomGeometry::span(const Box& box, Flat p, Flat q, float shrink, float& enter, float& leave) {
    // Into the wall's own frame: first axis along its length, second across its thickness.
    const float pl[2] = {(p.x - box.centre.x) * box.along.x + (p.z - box.centre.z) * box.along.z,
                         -(p.x - box.centre.x) * box.along.z + (p.z - box.centre.z) * box.along.x};
    const float ql[2] = {(q.x - box.centre.x) * box.along.x + (q.z - box.centre.z) * box.along.z,
                         -(q.x - box.centre.x) * box.along.z + (q.z - box.centre.z) * box.along.x};
    const float half[2] = {box.half_length - shrink, box.half_thickness - shrink};
    float t0 = 0.0f, t1 = 1.0f;
    for (int axis = 0; axis < 2; ++axis) {
        const float d = ql[axis] - pl[axis];
        if (std::fabs(d) < 1e-9f) {
            if (pl[axis] <= -half[axis] || pl[axis] >= half[axis]) return false;
        } else {
            const float ta = (-half[axis] - pl[axis]) / d, tb = (half[axis] - pl[axis]) / d;
            t0 = std::max(t0, std::min(ta, tb));
            t1 = std::min(t1, std::max(ta, tb));
            if (t0 >= t1) return false;
        }
    }
    enter = t0;
    leave = t1;
    return true;
}

bool RoomGeometry::crossesAny(Flat p, Flat q) const {
    float enter, leave;
    for (const Box& box : boxes_)
        if (span(box, p, q, kShrink, enter, leave)) return true;
    return false;
}

// Whether the straight line from ear to source passes through this wall, and how far along it does.
bool RoomGeometry::inLineOfSight(const Box& box, Vec3 ear, Vec3 source, float& enter) const {
    float leave;
    if (!span(box, {ear.x, ear.z}, {source.x, source.z}, 0.0f, enter, leave)) return false;
    const float rise = source.y - ear.y;
    return std::min(ear.y + rise * enter, ear.y + rise * leave) < box.top;  // otherwise it passes over the top
}

// The line of sight misses this wall: how much longer would the route touching its nearest edge be?
// Small values mean the sound only just clears the edge, where it already starts to dim.
float RoomGeometry::clearance(const Box& box, Vec3 ear, Vec3 source, float direct) const {
    const Flat a{ear.x, ear.z}, b{source.x, source.z};
    const float rise = source.y - ear.y;
    float nearest = 100.0f;
    const size_t first = size_t(&box - boxes_.data()) * 4;
    for (size_t c = first; c < first + 4; ++c) {
        const float flat = lengthOf(corners_[c].x - a.x, corners_[c].z - a.z) + lengthOf(b.x - corners_[c].x, b.z - corners_[c].z);
        nearest = std::min(nearest, std::sqrt(flat * flat + rise * rise) - direct);
    }
    float enter, leave;
    if (span(box, a, b, 0.0f, enter, leave)) {  // the line of sight passes over the top of the wall
        const float run = lengthOf(b.x - a.x, b.z - a.z);
        for (float t : {enter, leave}) {
            const float over = lengthOf(run * t, box.top - ear.y) + lengthOf(run * (1.0f - t), box.top - source.y);
            nearest = std::min(nearest, over - direct);
        }
    }
    return std::max(nearest, 0.0f);
}

// The shortest way round the walls on the floor plan, passing to either side of the wall the line of sight meets
// first. Which side a route passes is told by whether it crosses a line drawn outwards from that wall's centre, so
// the search keeps the shortest distance to each corner separately for routes that have and haven't crossed it.
void RoomGeometry::routesAround(const Box& first, Vec3 ear, Vec3 source, std::vector<Route>& out) const {
    const size_t n = corners_.size();
    const Flat a{ear.x, ear.z}, b{source.x, source.z};
    const float rise = source.y - ear.y;
    const Flat mark{-(b.z - a.z), b.x - a.x};  // the line's direction: square to the line of sight
    auto crossesMark = [&](Flat p, Flat q) {
        const float vx = q.x - p.x, vz = q.z - p.z;
        const float den = vx * mark.z - vz * mark.x;
        if (std::fabs(den) < 1e-12f) return false;
        const float ox = first.centre.x - p.x, oz = first.centre.z - p.z;
        const float along_leg = (ox * mark.z - oz * mark.x) / den, along_mark = (ox * vz - oz * vx) / den;
        return along_leg >= 0.0f && along_leg < 1.0f && along_mark > 0.0f;
    };
    auto distance = [&](size_t i, Flat p) { return lengthOf(corners_[i].x - p.x, corners_[i].z - p.z); };

    // From the source outwards. State 2*corner + (1 if the route from there to the source crosses the mark).
    std::vector<float> to_source(2 * n, kFar);
    std::vector<char> done(2 * n, 0);
    for (size_t i = 0; i < n; ++i)
        if (usable_[i] && !crossesAny(corners_[i], b)) to_source[2 * i + (crossesMark(corners_[i], b) ? 1 : 0)] = distance(i, b);
    for (size_t round = 0; round < 2 * n; ++round) {
        int nearest = -1;
        for (size_t state = 0; state < 2 * n; ++state)
            if (!done[state] && to_source[state] < kFar && (nearest < 0 || to_source[state] < to_source[size_t(nearest)])) nearest = int(state);
        if (nearest < 0) break;
        done[size_t(nearest)] = 1;
        const size_t from = size_t(nearest) / 2;
        for (size_t j = 0; j < n; ++j) {
            if (!visible_[from * n + j]) continue;
            const size_t state = 2 * j + ((size_t(nearest) & 1) ^ (crossesMark(corners_[j], corners_[from]) ? 1 : 0));
            const float through = to_source[size_t(nearest)] + distance(j, corners_[from]);
            if (!done[state] && through < to_source[state]) to_source[state] = through;
        }
    }

    // From the ear: every corner it can see starts a route. Keep the shortest on each side.
    Route best[2];
    bool found[2] = {false, false};
    for (size_t i = 0; i < n; ++i) {
        if (!usable_[i] || crossesAny(a, corners_[i])) continue;
        const float first_leg = distance(i, a);
        const int leg_crosses = crossesMark(a, corners_[i]) ? 1 : 0;
        for (int crossed = 0; crossed < 2; ++crossed) {
            if (to_source[2 * i + size_t(crossed)] >= kFar) continue;
            const float flat = first_leg + to_source[2 * i + size_t(crossed)];
            const float length = std::sqrt(flat * flat + rise * rise);
            const int side = crossed ^ leg_crosses;
            if (!found[side] || length < best[side].length) {
                found[side] = true;
                best[side].length = length;
                best[side].via = {corners_[i].x, ear.y + rise * first_leg / std::max(flat, 0.001f), corners_[i].z};
            }
        }
    }
    for (int side = 0; side < 2; ++side)
        if (found[side]) out.push_back(best[side]);
}

// Straight across the floor plan but up and over the walls in the way, like a string pulled tight over their tops.
// No such route if one of them reaches the ceiling.
bool RoomGeometry::routeOver(Vec3 ear, Vec3 source, Route& out) const {
    struct Point { float along, height; };
    const Flat a{ear.x, ear.z}, b{source.x, source.z};
    const float run = lengthOf(b.x - a.x, b.z - a.z);
    std::vector<Point> points{{0.0f, ear.y}};
    for (const Box& box : boxes_) {
        float enter, leave;
        if (!span(box, a, b, 0.0f, enter, leave)) continue;
        if (box.top >= ceiling_ - 0.05f) {
            const float rise = source.y - ear.y;
            if (std::min(ear.y + rise * enter, ear.y + rise * leave) < box.top) return false;  // it fills the gap to the ceiling
            continue;
        }
        points.push_back({run * enter, box.top});
        points.push_back({run * leave, box.top});
    }
    points.push_back({run, source.y});
    std::sort(points.begin() + 1, points.end() - 1, [](const Point& p, const Point& q) { return p.along < q.along; });

    std::vector<Point> hull;  // the upper side of the points' outline: what the string touches
    for (const Point& p : points) {
        while (hull.size() >= 2) {
            const Point& o = hull[hull.size() - 2];
            const Point& m = hull.back();
            if ((m.along - o.along) * (p.height - o.height) - (m.height - o.height) * (p.along - o.along) >= 0.0f) hull.pop_back();
            else break;
        }
        hull.push_back(p);
    }
    if (hull.size() < 3) return false;  // nothing in the way after all
    out.length = 0.0f;
    for (size_t i = 1; i < hull.size(); ++i) out.length += lengthOf(hull[i].along - hull[i - 1].along, hull[i].height - hull[i - 1].height);
    const float t = run > 1e-6f ? hull[1].along / run : 0.0f;
    out.via = {a.x + (b.x - a.x) * t, hull[1].height, a.z + (b.z - a.z) * t};
    return true;
}

std::array<float, 3> RoomGeometry::transmission(Vec3 a, Vec3 b) const {
    std::array<float, 3> through{1.0f, 1.0f, 1.0f};
    for (const Box& box : boxes_) {
        float enter;
        if (!inLineOfSight(box, a, b, enter)) continue;
        for (size_t band = 0; band < 3; ++band) through[band] *= box.through[band];
    }
    return through;
}

DirectPath RoomGeometry::directPath(Vec3 ear, Vec3 source) const {
    DirectPath path;
    path.via = source;
    const float dx = source.x - ear.x, dy = source.y - ear.y, dz = source.z - ear.z;
    const float direct = std::sqrt(dx * dx + dy * dy + dz * dz);

    const Box* first = nullptr;  // the wall the line of sight meets first
    float first_enter = 2.0f;
    for (const Box& box : boxes_) {
        float enter;
        if (inLineOfSight(box, ear, source, enter) && enter < first_enter) {
            first_enter = enter;
            first = &box;
        }
    }
    if (!first) {
        float nearest = 100.0f;
        for (const Box& box : boxes_) nearest = std::min(nearest, clearance(box, ear, source, direct));
        path.differences[0] = -nearest;
        path.count = 1;
        return path;
    }

    path.blocked = true;
    const std::array<float, 3> through = transmission(ear, source);
    std::copy(through.begin(), through.end(), path.through);
    std::vector<Route> routes;
    routesAround(*first, ear, source, routes);
    Route over;
    if (routeOver(ear, source, over)) routes.push_back(over);
    if (routes.empty()) {  // sealed in: only what leaks through the walls, straight
        path.count = 0;
        return path;
    }
    std::sort(routes.begin(), routes.end(), [](const Route& p, const Route& q) { return p.length < q.length; });
    path.count = int(std::min<size_t>(routes.size(), 3));
    for (int i = 0; i < path.count; ++i) path.differences[i] = routes[size_t(i)].length - direct;
    path.via = routes[0].via;
    const float vx = path.via.x - ear.x, vy = path.via.y - ear.y, vz = path.via.z - ear.z;
    path.extra = std::max(routes[0].length - std::sqrt(vx * vx + vy * vy + vz * vz), 0.0f);
    return path;
}

}  // namespace sr
