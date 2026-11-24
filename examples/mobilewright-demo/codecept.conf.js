import { createDemoFakeDriver } from './helpers/fakeMobileDriver.js';

export const config = {
  name: 'ceptra-mobilewright-demo',
  tests: './tests/*_test.js',
  output: './output',
  noGlobals: true,
  helpers: {
    Mobilewright: {
      require: '@codeceptjs/mobilewright',
      platform: 'android',
      app: 'com.saucelabs.mydemoapp.rn',
      deviceName: 'Ceptra Virtual Phone',
      driver: createDemoFakeDriver(),
      actionTimeout: 3000,
      waitForTimeout: 3000,
      animations: 'off',
    },
  },
  plugins: {
    screenshot: {
      enabled: true,
    },
  },
};
