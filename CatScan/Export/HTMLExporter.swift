import Foundation

/// Exports a scan as one self-contained web page: our GLB embedded as base64
/// plus a small hand-rolled WebGL viewer (orbit / pinch / wheel controls, lit
/// vertex colors). No CDN, no internet, no app required — AirDrop the file and
/// double-click it anywhere.
///
/// A custom viewer (~300 lines of JS) is deliberate: it only needs to read the
/// exact GLB layout our own GLBExporter writes, which keeps the page tiny
/// compared to bundling a general-purpose engine.
enum HTMLExporter {

    static func write(mesh: MeshData, includeColors: Bool, name: String, to url: URL) throws {
        let glb = try GLBExporter.data(mesh: mesh, includeColors: includeColors, name: name)
        let base64 = glb.base64EncodedString()
        let safeName = name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let stats = "\(mesh.vertexCount.formatted()) vertices · \(mesh.faceCount.formatted()) triangles"
        let html = template(title: safeName, stats: stats, base64: base64)
        try Data(html.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Page template

    private static func template(title: String, stats: String, base64: String) -> String {
        #"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <title>\#(title) — CatScan</title>
        <style>
          html, body { margin: 0; height: 100%; overflow: hidden;
            background: linear-gradient(180deg, #24262e 0%, #101217 100%);
            font-family: -apple-system, system-ui, "Segoe UI", Roboto, sans-serif; }
          canvas { display: block; width: 100vw; height: 100vh; touch-action: none; }
          .hud { position: fixed; left: 16px; bottom: 14px; color: #e8eaf0; pointer-events: none; }
          .hud h1 { font-size: 15px; margin: 0 0 2px; font-weight: 600; }
          .hud p { font-size: 11.5px; margin: 0; opacity: 0.65; }
          .badge { position: fixed; right: 16px; bottom: 14px; color: #9adcd2; font-size: 11.5px;
            opacity: 0.75; pointer-events: none; }
          .hint { position: fixed; top: 16px; left: 50%; transform: translateX(-50%);
            color: #cfd3dd; background: rgba(10,12,16,0.55); padding: 6px 14px; border-radius: 999px;
            font-size: 12px; transition: opacity 1s; pointer-events: none; }
          .err { position: fixed; top: 40%; width: 100%; text-align: center; color: #ff9f9f; font-size: 14px; }
        </style>
        </head>
        <body>
        <canvas id="c"></canvas>
        <div class="hud"><h1>\#(title)</h1><p>\#(stats)</p></div>
        <div class="badge">Scanned with CatScan</div>
        <div class="hint" id="hint">drag to orbit &nbsp;·&nbsp; pinch or scroll to zoom</div>
        <script id="model" type="text/plain">\#(base64)</script>
        <script>
        (function () {
          "use strict";
          function fail(msg) {
            var d = document.createElement("div");
            d.className = "err"; d.textContent = msg;
            document.body.appendChild(d);
            throw new Error(msg);
          }

          // ---- Decode the embedded GLB ----
          var b64 = document.getElementById("model").textContent.trim();
          var binStr = atob(b64);
          var bytes = new Uint8Array(binStr.length);
          for (var i = 0; i < binStr.length; i++) bytes[i] = binStr.charCodeAt(i);
          var buf = bytes.buffer;

          var dv = new DataView(buf);
          if (dv.getUint32(0, true) !== 0x46546C67) fail("Not a GLB file");
          var off = 12, json = null, bin = null;
          while (off < buf.byteLength) {
            var len = dv.getUint32(off, true);
            var type = dv.getUint32(off + 4, true);
            var chunk = buf.slice(off + 8, off + 8 + len);
            if (type === 0x4E4F534A) json = JSON.parse(new TextDecoder().decode(chunk));
            else if (type === 0x004E4942) bin = chunk;
            off += 8 + len;
          }
          if (!json || !bin) fail("Damaged model data");

          function accessorArray(index, Ctor, comps) {
            var acc = json.accessors[index];
            var bv = json.bufferViews[acc.bufferView];
            var byteOff = (bv.byteOffset || 0) + (acc.byteOffset || 0);
            return new Ctor(bin, byteOff, acc.count * comps);
          }
          var prim = json.meshes[0].primitives[0];
          var positions = accessorArray(prim.attributes.POSITION, Float32Array, 3);
          var normals = prim.attributes.NORMAL !== undefined
            ? accessorArray(prim.attributes.NORMAL, Float32Array, 3) : null;
          var colors = prim.attributes.COLOR_0 !== undefined
            ? accessorArray(prim.attributes.COLOR_0, Float32Array, 3) : null;
          var indices = accessorArray(prim.indices, Uint32Array, 1);
          var posAcc = json.accessors[prim.attributes.POSITION];
          var bmin = posAcc.min, bmax = posAcc.max;

          // ---- WebGL setup ----
          var canvas = document.getElementById("c");
          var gl = canvas.getContext("webgl2", { antialias: true });
          if (!gl) {
            gl = canvas.getContext("webgl", { antialias: true });
            if (!gl) fail("WebGL is not available in this browser");
            if (!gl.getExtension("OES_element_index_uint")) fail("Browser lacks 32-bit index support");
          }

          var vsSrc = [
            "attribute vec3 aPos;",
            "attribute vec3 aNormal;",
            "attribute vec3 aColor;",
            "uniform mat4 uMVP;",
            "varying vec3 vColor;",
            "varying vec3 vNormal;",
            "void main() {",
            "  gl_Position = uMVP * vec4(aPos, 1.0);",
            "  vNormal = aNormal;",
            "  vColor = aColor;",
            "}"].join("\n");
          var fsSrc = [
            "precision mediump float;",
            "varying vec3 vColor;",
            "varying vec3 vNormal;",
            "uniform vec3 uLight;",
            "void main() {",
            "  float l = 0.42 + 0.58 * abs(dot(normalize(vNormal), uLight));",
            "  gl_FragColor = vec4(vColor * l, 1.0);",
            "}"].join("\n");

          function shader(type, src) {
            var s = gl.createShader(type);
            gl.shaderSource(s, src);
            gl.compileShader(s);
            if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) fail(gl.getShaderInfoLog(s));
            return s;
          }
          var program = gl.createProgram();
          gl.attachShader(program, shader(gl.VERTEX_SHADER, vsSrc));
          gl.attachShader(program, shader(gl.FRAGMENT_SHADER, fsSrc));
          gl.linkProgram(program);
          if (!gl.getProgramParameter(program, gl.LINK_STATUS)) fail("Shader link failed");
          gl.useProgram(program);

          function attribBuffer(name, data, fallback) {
            var loc = gl.getAttribLocation(program, name);
            if (loc < 0) return;
            if (data) {
              var b = gl.createBuffer();
              gl.bindBuffer(gl.ARRAY_BUFFER, b);
              gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
              gl.enableVertexAttribArray(loc);
              gl.vertexAttribPointer(loc, 3, gl.FLOAT, false, 0, 0);
            } else {
              gl.disableVertexAttribArray(loc);
              gl.vertexAttrib3f(loc, fallback[0], fallback[1], fallback[2]);
            }
          }
          attribBuffer("aPos", positions, [0, 0, 0]);
          attribBuffer("aNormal", normals, [0, 1, 0]);
          attribBuffer("aColor", colors, [0.78, 0.78, 0.8]);

          var indexBuffer = gl.createBuffer();
          gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
          gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, indices, gl.STATIC_DRAW);

          gl.enable(gl.DEPTH_TEST);
          gl.disable(gl.CULL_FACE);
          gl.clearColor(0, 0, 0, 0);

          var uMVP = gl.getUniformLocation(program, "uMVP");
          var uLight = gl.getUniformLocation(program, "uLight");
          var inv = 1 / Math.sqrt(0.5 * 0.5 + 0.85 * 0.85 + 0.35 * 0.35);
          gl.uniform3f(uLight, 0.5 * inv, 0.85 * inv, 0.35 * inv);

          // ---- Matrix helpers ----
          function perspective(fovy, aspect, near, far) {
            var f = 1 / Math.tan(fovy / 2), nf = 1 / (near - far);
            return [f / aspect, 0, 0, 0,  0, f, 0, 0,
                    0, 0, (far + near) * nf, -1,  0, 0, 2 * far * near * nf, 0];
          }
          function lookAt(eye, target, up) {
            var zx = eye[0] - target[0], zy = eye[1] - target[1], zz = eye[2] - target[2];
            var zl = 1 / Math.hypot(zx, zy, zz); zx *= zl; zy *= zl; zz *= zl;
            var xx = up[1] * zz - up[2] * zy, xy = up[2] * zx - up[0] * zz, xz = up[0] * zy - up[1] * zx;
            var xl = 1 / (Math.hypot(xx, xy, xz) || 1); xx *= xl; xy *= xl; xz *= xl;
            var yx = zy * xz - zz * xy, yy = zz * xx - zx * xz, yz = zx * xy - zy * xx;
            return [xx, yx, zx, 0,  xy, yy, zy, 0,  xz, yz, zz, 0,
                    -(xx * eye[0] + xy * eye[1] + xz * eye[2]),
                    -(yx * eye[0] + yy * eye[1] + yz * eye[2]),
                    -(zx * eye[0] + zy * eye[1] + zz * eye[2]), 1];
          }
          function multiply(a, b) {
            var out = new Array(16);
            for (var c = 0; c < 4; c++)
              for (var r = 0; r < 4; r++)
                out[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] +
                                 a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
            return out;
          }

          // ---- Orbit state ----
          var center = [(bmin[0] + bmax[0]) / 2, (bmin[1] + bmax[1]) / 2, (bmin[2] + bmax[2]) / 2];
          var radius = Math.max(0.05, Math.hypot(bmax[0] - bmin[0], bmax[1] - bmin[1], bmax[2] - bmin[2]) / 2);
          var theta = 0.6, phi = 1.2, dist = radius * 2.6;
          var minDist = radius * 0.25, maxDist = radius * 12;
          var vTheta = 0.0025, vPhi = 0;

          var pointers = new Map();
          var lastPinch = 0;
          canvas.addEventListener("pointerdown", function (e) {
            pointers.set(e.pointerId, [e.clientX, e.clientY]);
            try { canvas.setPointerCapture(e.pointerId); } catch (err) {}
            vTheta = 0; vPhi = 0;
            var h = document.getElementById("hint");
            if (h) h.style.opacity = "0";
          });
          canvas.addEventListener("pointermove", function (e) {
            if (!pointers.has(e.pointerId)) return;
            var prev = pointers.get(e.pointerId);
            pointers.set(e.pointerId, [e.clientX, e.clientY]);
            if (pointers.size === 1) {
              var dx = (e.clientX - prev[0]) * 0.0065;
              var dy = (e.clientY - prev[1]) * 0.0065;
              theta += dx; phi -= dy;
              vTheta = dx * 0.55; vPhi = -dy * 0.55;
              phi = Math.min(2.9, Math.max(0.15, phi));
            } else if (pointers.size === 2) {
              var pts = Array.from(pointers.values());
              var pinch = Math.hypot(pts[0][0] - pts[1][0], pts[0][1] - pts[1][1]);
              if (lastPinch > 0) dist *= lastPinch / pinch;
              dist = Math.min(maxDist, Math.max(minDist, dist));
              lastPinch = pinch;
            }
          });
          function endPointer(e) {
            pointers.delete(e.pointerId);
            if (pointers.size < 2) lastPinch = 0;
          }
          canvas.addEventListener("pointerup", endPointer);
          canvas.addEventListener("pointercancel", endPointer);
          canvas.addEventListener("wheel", function (e) {
            e.preventDefault();
            dist *= Math.exp(e.deltaY * 0.0012);
            dist = Math.min(maxDist, Math.max(minDist, dist));
          }, { passive: false });
          canvas.addEventListener("dblclick", function () {
            theta = 0.6; phi = 1.2; dist = radius * 2.6; vTheta = 0.0025; vPhi = 0;
          });

          function resize() {
            var dpr = Math.min(2, window.devicePixelRatio || 1);
            var w = Math.round(canvas.clientWidth * dpr);
            var h = Math.round(canvas.clientHeight * dpr);
            if (canvas.width !== w || canvas.height !== h) {
              canvas.width = w; canvas.height = h;
              gl.viewport(0, 0, w, h);
            }
          }

          function frame() {
            resize();
            if (pointers.size === 0) {
              theta += vTheta; phi += vPhi;
              vTheta *= 0.95; vPhi *= 0.92;
              if (Math.abs(vTheta) < 0.0004) vTheta = Math.sign(vTheta || 1) * 0.0004;
              phi = Math.min(2.9, Math.max(0.15, phi));
            }
            var eye = [
              center[0] + dist * Math.sin(phi) * Math.sin(theta),
              center[1] + dist * Math.cos(phi),
              center[2] + dist * Math.sin(phi) * Math.cos(theta)];
            var proj = perspective(0.9, canvas.width / Math.max(1, canvas.height), radius * 0.01, radius * 40);
            var view = lookAt(eye, center, [0, 1, 0]);
            gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
            gl.uniformMatrix4fv(uMVP, false, new Float32Array(multiply(proj, view)));
            gl.drawElements(gl.TRIANGLES, indices.length, gl.UNSIGNED_INT, 0);
            requestAnimationFrame(frame);
          }
          requestAnimationFrame(frame);

          setTimeout(function () {
            var h = document.getElementById("hint");
            if (h) h.style.opacity = "0";
          }, 5000);
        })();
        </script>
        </body>
        </html>
        """#
    }
}
