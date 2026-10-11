#pragma once

// Where the walls inside the room are, and how an instrument's sound gets round them to the listener: which
// edge it bends around, how much longer that route is, and how narrowly a clear line of sight misses an edge.
// acoustics.h turns those lengths into how dull the sound gets.
//
// Used on the game thread only. The audio thread just receives the answers.

#include <vector>

#include "spatializer.h"

namespace sr {

// A straight wall standing on the floor: a box `thickness` wide running between two points on the floor plan and
// rising to `height`. It reaches half a thickness past each point, so walls drawn to a shared point close the corner.
struct Wall {
    float ax = 0, az = 0, bx = 0, bz = 0;
    float thickness = 0.3f;
    float height = 3.0f;
};

struct DirectPath {
    Vec3 via;                   // where the sound arrives from: the source itself, or the edge it bends around
    float extra = 0.0f;         // how far it travels beyond `via` to reach the source
    float differences[3] = {};  // how much longer each route is than the straight line, shortest first;
    int count = 0;              //   a single negative entry when the line of sight is clear (by how little)
    bool blocked = false;       // a wall stands in the line of sight
};

class RoomGeometry {
public:
    static constexpr int kMaxWalls = 16;

    // The room is `width` by `depth` on the floor plan, centred on the origin, and `ceiling` high. Walls taller than
    // the ceiling are cut off at it, and sound cannot go round a wall's end where it meets the room's own walls.
    // Any walls beyond kMaxWalls are ignored.
    void setRoom(float width, float depth, float ceiling, const std::vector<Wall>& walls);
    bool empty() const { return boxes_.empty(); }
    int wallCount() const { return int(boxes_.size()); }

    DirectPath directPath(Vec3 ear, Vec3 source) const;

private:
    struct Flat { float x = 0, z = 0; };
    struct Box {
        Flat centre, along;  // `along` is a unit vector down the wall's length
        float half_length = 0, half_thickness = 0, top = 0;
    };
    struct Route { float length = 0; Vec3 via; };

    // Where the flat segment p→q is inside a box's footprint (shrunk by `shrink`), as fractions along it.
    static bool span(const Box& box, Flat p, Flat q, float shrink, float& enter, float& leave);
    bool crossesAny(Flat p, Flat q) const;  // does a route's leg p→q pass through a wall?
    bool inLineOfSight(const Box& box, Vec3 ear, Vec3 source, float& enter) const;
    float clearance(const Box& box, Vec3 ear, Vec3 source, float direct) const;
    void routesAround(const Box& first, Vec3 ear, Vec3 source, std::vector<Route>& out) const;
    bool routeOver(Vec3 ear, Vec3 source, Route& out) const;

    std::vector<Box> boxes_;
    std::vector<Flat> corners_;      // four to a wall, nudged outwards so a route can pass along a wall's face
    std::vector<char> usable_;       // false for a corner buried in another wall
    std::vector<char> visible_;      // corners_.size() squared: whether a route can run straight between two corners
    float ceiling_ = 4.0f;
};

}  // namespace sr
