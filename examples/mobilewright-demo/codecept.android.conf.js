export const config = {
  name: 'ceptra-mobilewright-android',
  tests: './tests/*_test.js',
  output: './output',
  noGlobals: true,
  helpers: {
    Mobilewright: {
      require: '@codeceptjs/mobilewright',
      platform: 'android',
      app: 'com.saucelabs.mydemoapp.rn',
      actionTimeout: 10000,
      waitForTimeout: 10000,
      animations: 'off',
    },
  },
  plugins: {
    screenshot: {
      enabled: true,
    },
  },
};
