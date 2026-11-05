require "concurrent"

class ContactsController < ApplicationController
  # Pool dedicado para o fan-out (threads liberam o GVL enquanto esperam I/O)
  FANOUT_POOL = Concurrent::CachedThreadPool.new

  def index
    page = [params.fetch(:page, 1).to_i, 1].max
    page_size = params.fetch(:page_size, 25).to_i.clamp(1, 100)
    filters = params[:filter].is_a?(ActionController::Parameters) ? params[:filter] : {}
    f_stage = filters[:lead_stage].presence
    f_tag = filters[:tag].presence
    f_domain = filters[:email_domain].presence

    begin
      up = UpstreamClient.contacts.get_json("/contacts?page=#{page}&per_page=100")
    rescue UpstreamClient::Error, UpstreamClient::NotFound
      return render(json: { error: "contacts_unavailable" }, status: :bad_gateway)
    end

    data = []
    up["contacts"].each do |c|
      p = ContactPresenter.call(c)
      next if f_stage && p[:lead_stage] != f_stage
      next if f_tag && !p[:tags].include?(f_tag)
      next if f_domain && !p[:email].end_with?("@#{f_domain}")
      data << p
      break if data.size == page_size
    end

    render json: {
      data: data,
      meta: { page: page, page_size: page_size, count: data.size },
      links: { next: "/platform/contacts?page=#{page + 1}&page_size=#{page_size}" }
    }
  end

  def show
    id = params[:id]

    contact_f = future { UpstreamClient.contacts.get_json("/contacts/#{id}") }
    flows_f = future { UpstreamClient.optional.get_json("/automation/contacts/#{id}/flows") }
    channels_f = future { UpstreamClient.optional.get_json("/multichannel/contacts/#{id}/channels") }

    contact_ok, contact, contact_err = settle(contact_f)
    if !contact_ok && contact_err.is_a?(UpstreamClient::NotFound)
      return render(json: { error: "not_found" }, status: :not_found)
    end
    return render(json: { error: "contacts_unavailable" }, status: :bad_gateway) unless contact_ok

    degraded = []
    flows_ok, flows, = settle(flows_f)
    degraded << "automation" unless flows_ok
    channels_ok, channels, = settle(channels_f)
    degraded << "multichannel" unless channels_ok

    render json: {
      data: {
        contact: ContactPresenter.call(contact),
        automation: flows_ok ? { flows: flows["flows"] } : nil,
        channels: channels_ok ? channels["channels"] : nil
      },
      meta: { degraded: degraded }
    }
  end

  private

  def future(&block)
    Concurrent::Promises.future_on(FANOUT_POOL, &block)
  end

  # => [ok?, value, error]
  def settle(f)
    f.wait
    f.fulfilled? ? [true, f.value, nil] : [false, nil, f.reason]
  end
end
