require 'connection_pool'
require 'erb'

module React
  class Renderer

    class PrerenderError < RuntimeError
      def initialize(component_name, props, js_message)
        if props.length > 50
          props = props[0...47] + '...'
        end
        message = "Encountered error \"#{js_message}\" when prerendering #{component_name} with #{props}"
        super(message)
      end
    end

    cattr_accessor :pool

    def self.setup!(react_js, components_js, components_js_map, prerender_snippet, args={})
      args.assert_valid_keys(:size, :timeout)
      @@react_js = react_js
      @@components_js_map = components_js_map
      @@prerender_template = ERB.new(prerender_snippet)
      @@pool.shutdown{} if @@pool

      components_js_map.call.each do |k, v|
        reset_combined_js_map! k
      end

      default_pool_options = {:size =>10, :timeout => 20}
      @@pool = ConnectionPool.new(default_pool_options.merge(args)) { self.new }
    end

    def self.render(component, url_path, args={})
      @@pool.with do |renderer|
        renderer.render(component, url_path, args)
      end
    end

    def self.react_props(args={})
      if args.is_a? String
        args
      else
        args.to_json
      end
    end

    def context(cmp_name)
      @context ||= {}
      @context[cmp_name] ||= ExecJS.compile(self.class.combined_js_map[cmp_name])
    end

    def render(component, url_path, args={})
      react_props = React::Renderer.react_props(args)
      jscode = <<-JS
        function __reactRailsWrapper__(){
          var __outputObj__ = {outputValue: null};
          var __done__ = function(value){
            __outputObj__.outputValue = value;
          };

          // No-op just in case.
          function reactRailsRender(){}

          #{@@prerender_template.result(binding)}

          try {
            reactRailsRender(__done__);
          } catch (e) {
            __outputObj__.outputValue = e.stack;
            throw e;
          }
          return __outputObj__;
        }()
      JS
      context(component).eval(jscode)['outputValue'].html_safe
    rescue ExecJS::ProgramError => e
      puts "\nJavascript Error Message:".blue + " #{e}".red
      if ::Rails.env.development?
        source_str = self.class.combined_js + jscode
        puts "Stack Trace with context: (most recent call first)".blue
        i = 0
        e.backtrace.each do |frame|
          puts "Frame ##{i}:".blue
          puts frame
          i += 1
        end
      end
      raise PrerenderError.new(component, react_props, e)
    rescue Exception => e
      puts "\nJavascript Error Message:".blue + " #{e.value}".red
      if ::Rails.env.development?
        source_str = self.class.combined_js_map[component] + jscode
        puts "Stack Trace with context: (most recent call first)".blue
        i = 0
        e.javascript_backtrace.each do |frame|
          puts "Frame ##{i}:".blue
          puts stack_frame_to_s(frame, source_str)
          i += 1
        end
      end
      raise PrerenderError.new(component, react_props, e)
    end

    def stack_frame_to_s(frame, source_str)
      fline = frame.line_number - 1
      fstart = fline - 3
      fend = fline + 3

      frame_str = "<lines #{fstart + 1} through #{fend + 1}>: \n\t".blue
      frame_str += source_str.split("\n")[fstart...fline].join("\n\t")
      frame_str += "\n\t" + source_str.split("\n")[fline].red
      frame_str += "\n\t" + source_str.split("\n")[fline+1...fend].join("\n\t")
      frame_str += "\n"
      frame_str
    end


    private

    def self.setup_combined_js_map(cmp_name)
      <<-CODE
        var global = global || this;
        var self = self || this;
        var window = window || this;

        function setTimeout(fn, ms) {
          fn();
          return 0;
        };
        function clearTimeout() {};

        var localStorage = {};
        var document = {};

        var console = global.console || {};
        ['error', 'log', 'info', 'warn'].forEach(function (fn) {
          if (!(fn in console)) {
            console[fn] = function () {};
          }
        });

        #{@@components_js_map.call['Core']};
        React = global.React;
        #{@@components_js_map.call[cmp_name]};
      CODE
    end

    def self.reset_combined_js_map!(cmp_name)
      @@combined_js_map ||= {}
      @@combined_js_map[cmp_name] = setup_combined_js_map(cmp_name)
    end

    def self.combined_js_map
      @@combined_js_map
    end

  end
end
