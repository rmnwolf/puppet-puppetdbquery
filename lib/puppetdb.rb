require 'rubygems'
require 'puppetdb/util'
require 'puppetdb/matcher'
require 'json'
require 'net/http'
require 'net/https'

class PuppetDB
  def find_nodes_matching(host, port, query_string, only_active = false)
    stack = PuppetDB::Matcher.create_callstack(query_string)

    truth_values = []

    return query_puppetdb(host, port, :empty) if stack == []

    stack.each do |exp|
      case exp.keys.first
        when "statement"
          query   = parse_statement(exp)
          results = query_puppetdb(host, port, parse_statement(exp))
          results = query.keys.first == "resources" ? results.map{|f| f["certname"]} : results
          truth_values << results.inspect
        when "and"
          truth_values << "&"
        when "or"
          truth_values << "|"
        when "("
          truth_values << "("
        when ")"
          truth_values << ")"
      end
    end

    truth_values << '&' << query_puppetdb(host, port, get_active_query).inspect if only_active

    eval(truth_values.join(" "))

  end

  def find_node_facts(host, port, node_name, filter = [])

    facts = query_puppetdb(host, port, "facts" => node_name)
    return facts['facts'] if ! filter || filter.empty?
    # return an array with only facts specified in the filter
    return facts['facts'].reject{|k,v| ! filter.include?(k) }
  end

  def find_node_resources(host, port, node_name, resource_filter)
    # if there
    node_name = node_name ? ["=", ["node", "name"], node_name] : nil
    if resource_filter.empty?
      #str = ["and", ["=", ["node", "name"], "openstack-controller-20120802081343966964"]]
      query_puppetdb(host, port, {"resources" => ["and", node_name]})
    else
      # I should make a single resource query and not multiples
      query = resource_filter.collect do |r|
        query = parse_statement(r)
        query['resources'].push(node_name) if node_name
        query_puppetdb(host, port, query)[0]
      end
    end
  end

  # take an array of nodes returned with their resources to puppetdb and simplify
  # the data structure into something easier to read.
  # NOTE maybe arrays filtering methods could do this?
  def compact_nodes_resources(nodes)
    munged_hash = {}
    nodes.each do |resources|
      resources.compact.each do |resource|
        id = "#{resource['type']}[#{resource['title']}]"
        if munged_hash[id]
          # if the ids are the same, then push it, otherwise fail
          #require 'ruby-debug';debugger
          matching_index = -1
          munged_hash[id].each_index do |i|
            matching_index = i if munged_hash[id][i]['resource_hash'] == resource['resource']
          end
          if matching_index != -1
            # if we are a duplicate
            munged_hash[id][matching_index]['nodes'].push(resource['certname'])
          else
            # if we are not a duplicate
            munged_hash[id].push(simplify_resource(resource))
            munged_hash[id].last['nodes'] = [resource['certname']]
          end
        else
          munged_hash[id] = [simplify_resource(resource)]
          munged_hash[id].first['nodes'] = [resource['certname']]
        end
      end
    end
    munged_hash
  end

  # determines if a groups of reformatted resources have conflicts
  def has_conflicts?(resources)
    resources.each do |id, r|
      return id if r.size != 1
    end
    return false
  end

  # converts a resource_hash returned by puppetdb into something
  # much simpler
  def simplify_resource(resource_hash)
    {
      'parameters'    => resource_hash['parameters'],
      'resource_hash' => resource_hash['resource']
    }
  end

  def get_active_query
    { "nodes" => ["=", ["node", "active"], true] }
  end

  def parse_statement(statement)
    statement = statement.to_a.flatten.last

    if statement =~ /^([\w:]+)\[(.+)\]$/
      resource_type = $1.capitalize
      resource_name = $2

      if resource_name.start_with?('"') or resource_name.start_with?("'")
        raise(Puppet::Error, 'Resource titles should not be surrounded by quotes')
      end

      # in puppetdb class names are all capitalized but resource named arent
      resource_name = resource_name.split("::").map{|c| c.capitalize}.join("::") if resource_type == "Class"

      return {"resources" => ["and", ["=", "type", resource_type], ["=", "title", resource_name]]}
    elsif statement =~ /^(\w+)\s*=\s*(\w+)$/
      return {"nodes" => ["and" , ["=", ["fact", $1], $2]]}
    end
  end

  def query_puppetdb(host, port, query)
    http = Net::HTTP.new(host, port)
    #http.use_ssl = true
    #http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    if query == :empty

      resp, data = http.get("/nodes", {"accept" => "application/json"})
      return JSON.parse(data)

    else

      type   = query.keys.first
      headers = {"accept" => "application/json"}

      case type
        when "resources"
          query = "/resources?query=%s" % URI.escape(query[type].to_json)
          resp, data = http.get(query, headers)
          return JSON.parse(data)
        when "nodes"
          query = "/nodes?query=%s" % URI.escape(query[type].to_json)
          resp, data = http.get(query, headers)
          return JSON.parse(data)
        when "facts"
          query = "/facts/#{query[type]}"
          resp, data = http.get(query, headers)
          return JSON.parse(data)
      end
    end
  end
end
