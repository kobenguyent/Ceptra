import { secret } from 'codeceptjs';

Feature('Sauce Labs Mobile Store @mobile');

Scenario('verifies product catalog and installed app @smoke', async ({ I }) => {
  I.waitForText('Products', 10);
  I.see('Sauce Labs Backpack');
  I.seeAppIsInstalled('com.saucelabs.mydemoapp.rn');
  I.saveScreenshot('01-catalog.png');
});

Scenario('opens a product and adds it to cart @cart', async ({ I }) => {
  I.waitForText('Products', 10);
  I.longPress('~longpress reset app', 1);
  I.tap('Sauce Labs Backpack');
  I.waitForElement('~Add To Cart button', 5);
  I.tap('~Add To Cart button');
  I.see('1', '~cart badge');
  I.saveElementScreenshot('~cart badge', '02-cart-badge.png');
});

Scenario('signs in using adjacent field labels and deep link @auth', async ({ I }) => {
  I.waitForText('Products', 10);
  I.amOnPage('mydemoapprn://login');
  I.waitForElement('~Username input field', 5);
  I.fillField('Username', 'bob');
  I.appendField('Username', '@example.com');
  I.seeInField('~Username input field', 'bob@example.com');
  I.fillField('Password', secret('10203040'));
  I.tap('~Login button');
  I.saveScreenshot('03-after-login.png');
});

Scenario('rotates device orientation between landscape and portrait @device', async ({ I }) => {
  I.waitForText('Products', 10);
  I.setOrientation('LANDSCAPE');
  I.seeOrientationIs('LANDSCAPE');
  I.saveScreenshot('04-landscape.png');
  I.setOrientation('PORTRAIT');
  I.seeOrientationIs('PORTRAIT');
});
