export const config = {
  name: 'ceptra-mobilewright-ios',
  tests: './tests/*_test.js',
  output: './output',
  noGlobals: true,
  helpers: {
    Mobilewright: {
      require: '@codeceptjs/mobilewright',
      platform: 'ios',
      app: 'com.saucelabs.mydemoapp.rn',
      deviceName: 'iPhone',
      actionTimeout: 10000,
      waitForTimeout: 10000,
    },
  },
  plugins: {
    screenshot: {
      enabled: true,
    },
  },
};
