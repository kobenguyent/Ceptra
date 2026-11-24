import zlib from 'node:zlib';

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const t = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([t, data])), 0);
  return Buffer.concat([len, t, data, crc]);
}

function renderScreenPNG(driver) {
  const isLandscape = driver.orientation === 'landscape';
  const w = isLandscape ? 320 : 180;
  const h = isLandscape ? 180 : 320;
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;

  const rows = [];
  for (let y = 0; y < h; y++) {
    const row = Buffer.alloc(1 + w * 3);
    row[0] = 0;
    for (let x = 0; x < w; x++) {
      let r = 17;
      let g = 24;
      let b = 39;
      // Top navigation bar
      if (y < 28) {
        r = 30; g = 41; b = 59;
      }
      // Product card or login card region
      if (x >= 12 && x <= w - 12 && y >= 42 && y <= h - 48) {
        r = 31; g = 41; b = 55;
      }
      // Primary CTA button highlight (blue or green when item added to cart)
      if (x >= 16 && x <= w - 16 && y >= h - 40 && y <= h - 14) {
        if (driver.cartCount > 0) {
          r = 16; g = 185; b = 129;
        } else {
          r = 59; g = 130; b = 246;
        }
      }
      row[1 + x * 3] = r;
      row[2 + x * 3] = g;
      row[3 + x * 3] = b;
    }
    rows.push(row);
  }

  const raw = Buffer.concat(rows);
  const idat = zlib.deflateSync(raw);
  return Buffer.concat([
    sig,
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', idat),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

function node(props) {
  return {
    type: 'Other',
    isVisible: true,
    isEnabled: true,
    bounds: { x: 0, y: 0, width: 10, height: 10 },
    children: [],
    ...props,
  };
}

function buildViewTree(state) {
  return [
    node({
      type: 'FrameLayout',
      role: 'window',
      bounds: { x: 0, y: 0, width: 400, height: 800 },
      children: [
        node({
          type: 'TextView',
          role: 'header',
          text: 'Products',
          label: 'Products',
          bounds: { x: 16, y: 40, width: 200, height: 32 },
        }),
        node({
          type: 'Button',
          role: 'button',
          identifier: 'com.saucelabs.mydemoapp.rn:id/longpressReset',
          label: 'longpress reset app',
          text: 'Reset App',
          bounds: { x: 260, y: 40, width: 120, height: 32 },
        }),
        node({
          type: 'ViewGroup',
          identifier: 'com.saucelabs.mydemoapp.rn:id/cartBadge',
          label: 'cart badge',
          bounds: { x: 340, y: 80, width: 44, height: 28 },
          children: [
            node({
              type: 'TextView',
              text: String(state.cartCount),
              bounds: { x: 344, y: 82, width: 36, height: 24 },
            }),
          ],
        }),
        node({
          type: 'Button',
          role: 'button',
          identifier: 'com.saucelabs.mydemoapp.rn:id/storeBtn',
          label: 'store button',
          text: 'Sauce Labs Backpack',
          bounds: { x: 20, y: 120, width: 360, height: 64 },
        }),
        node({
          type: 'Button',
          role: 'button',
          identifier: 'com.saucelabs.mydemoapp.rn:id/addToCart',
          label: 'Add To Cart button',
          text: 'Add To Cart',
          bounds: { x: 20, y: 200, width: 360, height: 48 },
        }),
        node({
          type: 'TextView',
          text: 'Username',
          bounds: { x: 20, y: 280, width: 120, height: 22 },
        }),
        node({
          type: 'EditText',
          role: 'textfield',
          identifier: 'com.saucelabs.mydemoapp.rn:id/username',
          label: 'Username input field',
          placeholder: 'Username',
          value: state.username,
          bounds: { x: 20, y: 306, width: 360, height: 44 },
        }),
        node({
          type: 'TextView',
          text: 'Password',
          bounds: { x: 20, y: 366, width: 120, height: 22 },
        }),
        node({
          type: 'EditText',
          role: 'textfield',
          identifier: 'com.saucelabs.mydemoapp.rn:id/password',
          label: 'Password input field',
          placeholder: 'Password',
          value: state.password,
          bounds: { x: 20, y: 392, width: 360, height: 44 },
        }),
        node({
          type: 'Button',
          role: 'button',
          identifier: 'com.saucelabs.mydemoapp.rn:id/loginBtn',
          label: 'Login button',
          text: 'Sign In',
          bounds: { x: 20, y: 460, width: 360, height: 48 },
        }),
      ],
    }),
  ];
}

function flatten(nodes, out = []) {
  for (const n of nodes) {
    out.push(n);
    if (Array.isArray(n.children)) flatten(n.children, out);
  }
  return out;
}

export function createDemoFakeDriver() {
  const state = {
    cartCount: 0,
    username: '',
    password: '',
    focusedId: null,
  };

  const driver = {
    calls: [],
    apps: [{ bundleId: 'com.saucelabs.mydemoapp.rn', name: 'Sauce Labs Demo' }],
    foreground: 'com.saucelabs.mydemoapp.rn',
    orientation: 'portrait',
    get cartCount() {
      return state.cartCount;
    },
    async listDevices() {
      return [{ id: 'ceptra-sim-1', name: 'Ceptra Virtual Phone', platform: 'android', type: 'emulator', state: 'online' }];
    },
    async connect(config) {
      driver.calls.push(['connect', config.deviceId]);
      return { deviceId: config.deviceId, platform: config.platform };
    },
    async disconnect() {
      driver.calls.push(['disconnect']);
    },
    async getViewHierarchy() {
      return buildViewTree(state);
    },
    async tap(x, y) {
      driver.calls.push(['tap', x, y]);
      const tree = buildViewTree(state);
      const hits = flatten(tree).filter(
        (n) => x >= n.bounds.x && x <= n.bounds.x + n.bounds.width && y >= n.bounds.y && y <= n.bounds.y + n.bounds.height
      );
      const target = hits.at(-1) ?? null;
      if (!target) return;
      state.focusedId = target.identifier || target.label || null;
      if (target.label === 'Add To Cart button') {
        state.cartCount += 1;
      }
    },
    async doubleTap(x, y) {
      driver.calls.push(['doubleTap', x, y]);
    },
    async longPress(x, y, duration) {
      driver.calls.push(['longPress', x, y, duration]);
      if (y <= 80) {
        state.cartCount = 0;
      }
    },
    async typeText(text) {
      driver.calls.push(['typeText', text]);
      if (state.focusedId && state.focusedId.includes('password')) {
        state.password += text;
      } else {
        state.username += text;
      }
    },
    async clearText() {
      driver.calls.push(['clearText']);
      if (state.focusedId && state.focusedId.includes('password')) {
        state.password = '';
      } else {
        state.username = '';
      }
    },
    async pressKeys() {},
    async swipe(direction, opts) {
      driver.calls.push(['swipe', direction, opts]);
    },
    async gesture() {},
    async pressButton(button) {
      driver.calls.push(['pressButton', button]);
    },
    async screenshot() {
      return renderScreenPNG(driver);
    },
    async getScreenSize() {
      return driver.orientation === 'landscape'
        ? { width: 800, height: 400, scale: 2 }
        : { width: 400, height: 800, scale: 2 };
    },
    async getOrientation() {
      return driver.orientation;
    },
    async setOrientation(o) {
      driver.orientation = String(o).toLowerCase();
    },
    async setGeolocation() {},
    async setFoldState() {},
    async launchApp(bundleId) {
      driver.calls.push(['launchApp', bundleId]);
      driver.foreground = bundleId;
    },
    async terminateApp(bundleId) {
      driver.calls.push(['terminateApp', bundleId]);
    },
    async listApps() {
      return driver.apps;
    },
    async getForegroundApp() {
      return { bundleId: driver.foreground };
    },
    async installApp(path) {
      driver.calls.push(['installApp', path]);
    },
    async uninstallApp(bundleId) {
      driver.calls.push(['uninstallApp', bundleId]);
    },
    async openUrl(url) {
      driver.calls.push(['openUrl', url]);
    },
    async startRecording() {},
    async stopRecording() {
      return {};
    },
    async allocate() {
      return { deviceId: 'ceptra-sim-1', platform: 'android' };
    },
    async release() {},
  };

  return driver;
}
