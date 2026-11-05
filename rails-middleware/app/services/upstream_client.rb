require "net/http/persistent"
require "json"

# Cliente dos serviços de domínio. Uma instância persistente por classe de timeout,
# espelhando os timeouts por domínio da versão Go (contatos 1s, opcionais 300ms).
class UpstreamClient
  class NotFound < StandardError; end
  class Error < StandardError; end

  BASE_URL = ENV.fetch("UPSTREAM_URL", "http://localhost:9000")

  def self.contacts
    @contacts ||= new(timeout: 1.0, name: "contacts")
  end

  def self.optional
    @optional ||= new(timeout: 0.3, name: "optional")
  end

  def initialize(timeout:, name:)
    @http = Net::HTTP::Persistent.new(name: name, pool_size: 256)
    @http.open_timeout = timeout
    @http.read_timeout = timeout
    @http.idle_timeout = 90
  end

  def get_json(path)
    uri = URI("#{BASE_URL}#{path}")
    res = @http.request(uri)
    case res.code.to_i
    when 200..299 then JSON.parse(res.body)
    when 404 then raise NotFound
    else raise Error, "status #{res.code}"
    end
  rescue Net::HTTP::Persistent::Error, Net::OpenTimeout, Net::ReadTimeout, SystemCallError => e
    raise Error, e.message
  end
end
