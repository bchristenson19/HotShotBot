import AppKit
import SceneKit

/// The virtual camera's 3D scene — native SceneKit port of `lib/virtualScene.ts` +
/// `lib/virtualActor.ts`. Builds a static room (floor, lights, reference boxes, back wall, fog)
/// and a procedurally-animated, human-proportioned walking figure, plus the `SCNCamera` node the
/// `VirtualPtzController` pose is applied to.
///
/// The figure is built at true-ish human proportions (~1.78 m, ~7 head-heights) with flat matte
/// colors deliberately, exactly as in the TS original: it's what makes Vision's person detector
/// (`PersonDetector`) fire on the rendered silhouette, so the whole tracking pipeline runs against
/// the virtual feed. All joint angles are a pure function of elapsed time — `updateActor(elapsed:)`
/// recomputes them from scratch each frame, no per-frame state.
///
/// Not `@MainActor`: `VirtualCameraRenderer` builds and drives this entirely on its own render
/// queue, off the main thread.
final class VirtualScene {

    let scene = SCNScene()
    let cameraNode = SCNNode()

    // Actor joint nodes animated each frame (see `updateActor`).
    private let actorRoot = SCNNode()
    private let torso = SCNNode()
    private let leftHip = SCNNode()
    private let rightHip = SCNNode()
    private let leftKnee = SCNNode()
    private let rightKnee = SCNNode()
    private let leftShoulder = SCNNode()
    private let rightShoulder = SCNNode()
    private let leftElbow = SCNNode()
    private let rightElbow = SCNNode()

    // MARK: Actor proportions (metres) — verbatim from lib/virtualActor.ts.
    private static let headR = 0.11
    private static let torsoH = 0.65, torsoW = 0.34, torsoD = 0.20
    private static let upperArmL = 0.30, lowerArmL = 0.28, armR = 0.05
    private static let upperLegL = 0.45, lowerLegL = 0.42, legR = 0.07, footL = 0.24

    // MARK: Walk path — closed rectangle on the XZ plane, traced at PATH_SPEED m/s.
    private static let path: [(x: Double, z: Double)] = [(-2.5, -1.2), (2.5, -1.2), (2.5, 1.2), (-2.5, 1.2)]
    private static let pathSpeed = 0.8
    private static let stepHz = 1.6

    init() {
        buildEnvironment()
        buildActor()
        scene.rootNode.addChildNode(actorRoot)
    }

    // MARK: Environment (lib/virtualScene.ts)

    private func buildEnvironment() {
        let bg = Self.color(0x1a2530)
        scene.background.contents = bg

        // Linear fog matching the background, so distant geometry fades out (Fog near 8, far 25).
        scene.fogStartDistance = 8
        scene.fogEndDistance = 25
        scene.fogColor = bg
        scene.fogDensityExponent = 1

        // Camera — at ~eye height near one end of the walk path, looking down -Z (SceneKit's
        // default forward, same as Three.js). Vertical FOV to match Three.js PerspectiveCamera.fov.
        let cam = SCNCamera()
        cam.fieldOfView = 60
        cam.projectionDirection = .vertical
        cam.zNear = 0.1
        cam.zFar = 100
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, 1.55, 3.5)
        scene.rootNode.addChildNode(cameraNode)

        // Soft cool ambient standing in for Three.js's HemisphereLight, plus a key directional.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = Self.color(0x8fa8c8)
        ambient.intensity = 550
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.color = NSColor.white
        key.intensity = 1000
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(5, 8, 4)
        keyNode.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(keyNode)

        // Floor: a 30×30 plane laid flat at y=0.
        let floor = SCNPlane(width: 30, height: 30)
        floor.firstMaterial = Self.material(0x3f5060, roughness: 0.95)
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(floorNode)

        // Reference props so pan/tilt/zoom motion reads visually.
        let box1 = SCNNode(geometry: SCNBox(width: 0.9, height: 0.9, length: 0.9, chamferRadius: 0))
        box1.geometry?.firstMaterial = Self.material(0xa26f3d, roughness: 0.85)
        box1.position = SCNVector3(-2.2, 0.45, 0.4)
        scene.rootNode.addChildNode(box1)

        let box2 = SCNNode(geometry: SCNBox(width: 0.6, height: 1.3, length: 0.6, chamferRadius: 0))
        box2.geometry?.firstMaterial = Self.material(0xa26f3d, roughness: 0.85)
        box2.position = SCNVector3(2.2, 0.65, 0.2)
        scene.rootNode.addChildNode(box2)

        // Back wall — keeps pan/tilt legible even when the actor is offscreen.
        let wall = SCNNode(geometry: SCNBox(width: 14, height: 4, length: 0.2, chamferRadius: 0))
        wall.geometry?.firstMaterial = Self.material(0x8a5a3c, roughness: 0.9)
        wall.position = SCNVector3(0, 2, -4)
        scene.rootNode.addChildNode(wall)
    }

    // MARK: Actor rig (lib/virtualActor.ts)

    private func buildActor() {
        let skin = Self.material(0xd9a273, roughness: 0.85)
        let shirt = Self.material(0x2563eb, roughness: 0.7)
        let pants = Self.material(0x1e293b, roughness: 0.9)
        let shoe = Self.material(0x0f172a, roughness: 0.6)

        // pelvis sits at hip height (leg length up from the ground).
        let pelvis = SCNNode()
        pelvis.position = SCNVector3(0, Self.upperLegL + Self.lowerLegL, 0) // 0.87
        actorRoot.addChildNode(pelvis)

        // Torso group pivots at the pelvis top; z-lean is animated on it.
        pelvis.addChildNode(torso)

        let torsoBox = SCNNode(geometry: SCNBox(width: CGFloat(Self.torsoW), height: CGFloat(Self.torsoH),
                                                length: CGFloat(Self.torsoD), chamferRadius: 0.02))
        torsoBox.geometry?.firstMaterial = shirt
        torsoBox.position = SCNVector3(0, Self.torsoH / 2, 0)
        torso.addChildNode(torsoBox)

        let head = SCNNode(geometry: SCNSphere(radius: CGFloat(Self.headR)))
        head.geometry?.firstMaterial = skin
        head.position = SCNVector3(0, Self.torsoH + Self.headR + 0.04, 0) // 0.80
        torso.addChildNode(head)

        // Arms — shoulder joint → upper arm → elbow joint → lower arm.
        let shoulderY = Self.torsoH - 0.03            // 0.62
        let shoulderX = Self.torsoW / 2 + Self.armR * 0.8 // 0.21
        buildArm(shoulder: leftShoulder, elbow: leftElbow, side: -1,
                 at: SCNVector3(-shoulderX, shoulderY, 0), skin: skin, parent: torso)
        buildArm(shoulder: rightShoulder, elbow: rightElbow, side: 1,
                 at: SCNVector3(shoulderX, shoulderY, 0), skin: skin, parent: torso)

        // Legs — hip joint (child of pelvis) → upper leg → knee joint → lower leg → foot.
        let hipX = Self.torsoW / 4 + Self.legR * 0.5  // 0.12
        buildLeg(hip: leftHip, knee: leftKnee, at: SCNVector3(-hipX, 0, 0), pants: pants, shoe: shoe, parent: pelvis)
        buildLeg(hip: rightHip, knee: rightKnee, at: SCNVector3(hipX, 0, 0), pants: pants, shoe: shoe, parent: pelvis)
    }

    private func buildArm(shoulder: SCNNode, elbow: SCNNode, side: Double, at position: SCNVector3,
                          skin: SCNMaterial, parent: SCNNode) {
        shoulder.position = position
        parent.addChildNode(shoulder)
        shoulder.addChildNode(Self.limbSegment(length: Self.upperArmL, radius: Self.armR, material: skin))

        elbow.position = SCNVector3(0, -Self.upperArmL, 0)
        shoulder.addChildNode(elbow)
        elbow.addChildNode(Self.limbSegment(length: Self.lowerArmL, radius: Self.armR, material: skin))
    }

    private func buildLeg(hip: SCNNode, knee: SCNNode, at position: SCNVector3,
                          pants: SCNMaterial, shoe: SCNMaterial, parent: SCNNode) {
        hip.position = position
        parent.addChildNode(hip)
        hip.addChildNode(Self.limbSegment(length: Self.upperLegL, radius: Self.legR, material: pants))

        knee.position = SCNVector3(0, -Self.upperLegL, 0)
        hip.addChildNode(knee)
        knee.addChildNode(Self.limbSegment(length: Self.lowerLegL, radius: Self.legR, material: pants))

        let foot = SCNNode(geometry: SCNBox(width: CGFloat(Self.legR * 1.8), height: CGFloat(Self.legR * 0.9),
                                            length: CGFloat(Self.footL), chamferRadius: 0.01))
        foot.geometry?.firstMaterial = shoe
        foot.position = SCNVector3(0, -Self.lowerLegL - Self.legR * 0.45, Self.footL / 2 - Self.legR * 0.6)
        knee.addChildNode(foot)
    }

    /// A limb segment whose geometry hangs BELOW its node origin, so the parent joint rotates it
    /// about its top — the "translate geometry down by -length/2" pattern from the TS `limbSegment`.
    /// SceneKit's `SCNCylinder` is Y-axis aligned and centered, so a `-length/2` offset does it.
    private static func limbSegment(length: Double, radius: Double, material: SCNMaterial) -> SCNNode {
        let cyl = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cyl.firstMaterial = material
        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3(0, -length / 2, 0)
        return node
    }

    // MARK: Per-frame animation (update(t) in lib/virtualActor.ts)

    /// Recomputes the walk position and every joint angle from `elapsed` seconds. Pure function of
    /// time — stateless, so any frame can be produced directly.
    func updateActor(elapsed t: Double) {
        let p = Self.pointOnPath(distance: t * Self.pathSpeed)

        let phase = t * Self.stepHz * 2 * .pi
        let hipSwing = sin(phase) * 0.55
        let kneeBendL = max(0, sin(phase)) * 1.05
        let kneeBendR = max(0, sin(phase + .pi)) * 1.05
        let bob = abs(sin(phase * 2)) * 0.03

        actorRoot.position = SCNVector3(p.x, bob, p.z)
        actorRoot.eulerAngles.y = CGFloat(p.heading)

        leftHip.eulerAngles.x = CGFloat(hipSwing)
        rightHip.eulerAngles.x = CGFloat(-hipSwing)
        leftKnee.eulerAngles.x = CGFloat(kneeBendL)
        rightKnee.eulerAngles.x = CGFloat(kneeBendR)

        leftShoulder.eulerAngles.x = CGFloat(-hipSwing * 0.9)
        rightShoulder.eulerAngles.x = CGFloat(hipSwing * 0.9)
        leftElbow.eulerAngles.x = CGFloat(-0.25 - kneeBendR * 0.15)
        rightElbow.eulerAngles.x = CGFloat(-0.25 - kneeBendL * 0.15)

        torso.eulerAngles.z = CGFloat(sin(phase) * 0.05)
    }

    /// Position + facing-heading along the closed rectangular path at `distance` metres traveled.
    /// `heading = atan2(Δx, Δz)` (note: x-over-z, matching the TS), suitable for `eulerAngles.y`.
    private static func pointOnPath(distance: Double) -> (x: Double, z: Double, heading: Double) {
        // Segment lengths around the closed loop.
        var segs: [(ax: Double, az: Double, bx: Double, bz: Double, len: Double)] = []
        var total = 0.0
        for i in 0..<path.count {
            let a = path[i]
            let b = path[(i + 1) % path.count]
            let len = ((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z)).squareRoot()
            segs.append((a.x, a.z, b.x, b.z, len))
            total += len
        }

        // Wrap distance into [0, total), handling negatives.
        var d = distance.truncatingRemainder(dividingBy: total)
        if d < 0 { d += total }

        for s in segs {
            if d <= s.len {
                let t = s.len == 0 ? 0 : d / s.len
                let x = s.ax + (s.bx - s.ax) * t
                let z = s.az + (s.bz - s.az) * t
                let heading = atan2(s.bx - s.ax, s.bz - s.az)
                return (x, z, heading)
            }
            d -= s.len
        }
        // Fallback (shouldn't happen): start of the loop.
        return (segs[0].ax, segs[0].az, atan2(segs[0].bx - segs[0].ax, segs[0].bz - segs[0].az))
    }

    // MARK: Color / material helpers

    private static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    private static func material(_ hex: Int, roughness: Double) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color(hex)
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        return m
    }
}
