'use strict';

function createSecretStore({ app, safeStorage, fs, path }) {
  const secretFile = () => path.join(app.getPath('userData'), 'secrets.json');
  const readSecrets = () => {
    try {
      return JSON.parse(fs.readFileSync(secretFile(), 'utf8'));
    } catch {
      return {};
    }
  };

  return {
    set(key, value) {
      if (!safeStorage.isEncryptionAvailable()) {
        throw new Error('Windows 安全凭据加密当前不可用');
      }
      const data = readSecrets();
      data[key] = safeStorage.encryptString(value).toString('base64');
      fs.writeFileSync(secretFile(), JSON.stringify(data));
      return true;
    },
    get(key) {
      const value = readSecrets()[key];
      return value ? safeStorage.decryptString(Buffer.from(value, 'base64')) : '';
    }
  };
}

module.exports = { createSecretStore };
