// Downloads TF.js and COCO-SSD model files to public/tfjs for offline bundling.
const fs = require("fs");
const path = require("path");
const https = require("https");

const OUT = path.join(__dirname, "../public/tfjs");
const MODEL_OUT = path.join(OUT, "models/coco-ssd");

fs.mkdirSync(OUT, { recursive: true });
fs.mkdirSync(MODEL_OUT, { recursive: true });

// Resolves the expected byte size of a URL via a HEAD request, following redirects.
function headSize(url) {
  return new Promise((resolve, reject) => {
    https.get(url, { method: "HEAD" }, (res) => {
      // HEAD responses have no body, but the socket won't be freed — and the
      // process won't exit — until the response stream is drained.
      res.resume();
      if (res.statusCode === 301 || res.statusCode === 302) {
        headSize(res.headers.location).then(resolve, reject);
        return;
      }
      const len = parseInt(res.headers["content-length"] ?? "", 10);
      resolve(Number.isFinite(len) ? len : null);
    }).on("error", reject);
  });
}

// Downloads url to dest, skipping only if an existing file's size already matches
// the remote's Content-Length — a merely-existing file may be a truncated leftover
// from an interrupted run, so existence alone isn't proof of completeness.
async function download(url, dest) {
  const expected = await headSize(url);
  if (fs.existsSync(dest)) {
    const actual = fs.statSync(dest).size;
    if (expected === null || actual === expected) {
      console.log(`  skip (verified): ${path.basename(dest)}`);
      return;
    }
    console.log(`  redownloading (${actual}/${expected} bytes, incomplete): ${path.basename(dest)}`);
  }
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    https.get(url, (res) => {
      if (res.statusCode === 301 || res.statusCode === 302) {
        file.close(); fs.unlinkSync(dest);
        download(res.headers.location, dest).then(resolve).catch(reject);
        return;
      }
      if (res.statusCode !== 200) {
        file.close(); fs.unlinkSync(dest);
        reject(new Error(`${url} → HTTP ${res.statusCode}`));
        return;
      }
      res.pipe(file);
      file.on("finish", () => {
        file.close();
        const actual = fs.statSync(dest).size;
        if (expected !== null && actual !== expected) {
          fs.unlinkSync(dest);
          reject(new Error(`${url} → downloaded ${actual} bytes, expected ${expected}`));
          return;
        }
        console.log(`  ✓ ${path.basename(dest)}`);
        resolve();
      });
    }).on("error", (e) => { fs.unlinkSync(dest); reject(e); });
  });
}

async function main() {
  console.log("Downloading TF.js files...");

  const nmBase = path.join(__dirname, "../node_modules");

  // Copy from node_modules (already installed)
  const copies = [
    [`${nmBase}/@tensorflow/tfjs/dist/tf.min.js`, `${OUT}/tf.min.js`],
    [`${nmBase}/@tensorflow/tfjs-backend-webgl/dist/tf-backend-webgl.min.js`, `${OUT}/tf-backend-webgl.min.js`],
    [`${nmBase}/@tensorflow-models/coco-ssd/dist/coco-ssd.min.js`, `${OUT}/coco-ssd.min.js`],
  ];
  for (const [src, dst] of copies) {
    if (fs.existsSync(dst)) { console.log(`  skip (exists): ${path.basename(dst)}`); continue; }
    fs.copyFileSync(src, dst);
    console.log(`  ✓ ${path.basename(dst)}`);
  }

  console.log("Downloading COCO-SSD model weights...");
  const BASE = "https://storage.googleapis.com/tfjs-models/savedmodel/ssd_mobilenet_v2";
  await download(`${BASE}/model.json`, `${MODEL_OUT}/model.json`);
  const shards = Array.from({ length: 17 }, (_, i) => `group1-shard${i+1}of17`);
  await Promise.all(shards.map(s => download(`${BASE}/${s}`, `${MODEL_OUT}/${s}`)));

  console.log("Done.");
}

main().catch((e) => { console.error(e); process.exit(1); });
