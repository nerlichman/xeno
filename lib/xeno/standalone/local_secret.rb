# frozen_string_literal: true

require "securerandom"
require "fileutils"

module Xeno
  module Standalone
    module_function

    # A persisted local secret so standalone sessions survive restarts without anyone managing
    # SECRET_KEY_BASE. Owner-only (0600) — it signs cookies/sessions; looser pre-existing files are
    # tightened on read.
    #
    # Lives apart from xeno/standalone so tests can exercise it without defining the
    # Rails::Application (which self-registers on inheritance).
    def local_secret(root)
      path = root.join("storage", ".local_secret")
      FileUtils.mkdir_p(path.dirname)
      if path.file?
        File.chmod(0o600, path)
        return path.read.strip
      end

      SecureRandom.hex(64).tap { |secret| File.write(path, secret, perm: 0o600) }
    end
  end
end
