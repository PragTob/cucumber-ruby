require 'forwardable'
require 'delegate'

module Cucumber
  module Formatter

    FormatterWrapper = Struct.new(:formatter) do
      def method_missing(message, *args)
        formatter.send(message, *args) if formatter.respond_to?(message)
      end
    end

    ReportAdapter = Struct.new(:runtime, :formatter) do
      def initialize(runtime, formatter)
        super runtime, FormatterWrapper.new(formatter)
      end

      extend Forwardable

      def_delegators :formatter,
        :embed,
        :ask,
        :puts

      def before_test_case(test_case); end
      def before_test_step(test_step); end

      def after_test_step(test_step, result)
        DebugPrinter.new(test_step) if ENV['DEBUG']
        test_step.describe_source_to(printer, result)
      end

      def after_test_case(test_case, result)
        record_test_case_result(test_case, result)
      end

      def after_suite
        printer.after
      end

      class DebugPrinter
        def initialize(step)
          @messages = []
          step.describe_to self
          @messages << step.name if step.respond_to? :name
          step.describe_source_to self
          p @messages
        end
        def method_missing(message, *args)
          @messages << message
        end
      end

      private

      def printer
        @printer ||= FeaturesPrinter.new(formatter, runtime).before
      end

      def record_test_case_result(test_case, result)
        scenario = LegacyResultBuilder.new(result).scenario(test_case.name, test_case.location.to_s)
        runtime.record_result(scenario)
        yield scenario if block_given?
      end


      # Provides a DSL for making the printers themselves more terse
      class Printer < Struct
        def self.before(&block)
          define_method(:before) do
            instance_eval(&block)
            self
          end
        end

        def self.after(&block)
          define_method(:after) do
            @child.after if @child
            instance_eval(&block)
            self
          end
        end

        def delegate_to(printer_type, node)
          for_new(node) do
            args = [formatter, runtime, node]
            @child.after if @child
            @child = printer_type.new(*args).before
          end
        end

        def for_new(node, &block)
          @current_nodes ||= {}
          if @current_nodes[node.class] != node
            @current_nodes[node.class] = node
            block.call
          end
        end
      end

      require 'cucumber/core/test/timer'
      FeaturesPrinter = Printer.new(:formatter, :runtime) do
        before do
          timer.start
          formatter.before_features(nil)
        end

        def hook(result)
          LegacyResultBuilder.new(result).describe_exception_to(formatter)
        end

        def feature(feature, *)
          delegate_to FeaturePrinter, feature
        end

        def background(node, result)
          @child.background(node, result)
        end

        def step(node, result)
          @child.step(node, result)
        end

        def scenario(node, result)
          @child.scenario(node, result)
        end

        def scenario_outline(node, result)
          @child.scenario_outline(node, result)
        end

        def examples_table(node, result)
          @child.examples_table(node, result)
        end

        def examples_table_row(node, result)
          @child.examples_table_row(node, result)
        end

        after do
          formatter.after_features LegacyFeatures.new(timer.sec)
        end

        private

        def timer
          @timer ||= Cucumber::Core::Test::Timer.new
        end

        LegacyFeatures = Struct.new(:duration)
      end

      FeaturePrinter = Printer.new(:formatter, :runtime, :feature) do
        before do
          formatter.before_feature(feature)
          Legacy::Ast::Comments.new(feature.comments).describe_to(formatter)
          Legacy::Ast::Tags.new(feature.tags).describe_to(formatter)
          formatter.feature_name feature.keyword, indented(feature.name) # TODO: change the core's new AST to return name and description separately instead of this lumped-together field
        end

        def background(background, *)
          delegate_to BackgroundPrinter, background
        end

        def scenario(scenario, *)
          delegate_to ScenarioPrinter, scenario
        end

        def step(node, result)
          @child.step(node, result)
        end

        def scenario_outline(scenario_outline, *)
          delegate_to ScenarioOutlinePrinter, scenario_outline
        end

        def examples_table(node, result)
          @child.examples_table(node, result)
        end

        def examples_table_row(node, result)
          @child.examples_table_row(node, result)
        end

        after do
          formatter.after_feature(feature)
        end

        private

        def indented(nasty_old_conflation_of_name_and_description)
          indent = ""
          nasty_old_conflation_of_name_and_description.split("\n").map do |l|
            s = "#{indent}#{l}"
            indent = "  "
            s
          end.join("\n")
        end
      end

      BackgroundPrinter = Printer.new(:formatter, :runtime, :background) do

        before do
          formatter.before_background background
          formatter.background_name background.keyword, background.name, background.location.to_s, indent.of(background)
        end

        def step(step, result)
          @child ||= StepsPrinter.new(formatter).before
          step_result = LegacyResultBuilder.new(result).step_result(step_match(step), background)
          runtime.step_visited step_result
          @child.step step, step_result, runtime, indent, background
        end

        after do
          formatter.after_background(background)
        end

        private

        def step_match(step)
          runtime.step_match(step.name)
        rescue Cucumber::Undefined
          NoStepMatch.new(step, step.name)
        end

        def indent
          @indent ||= Indent.new(background)
        end
      end

      ScenarioPrinter = Printer.new(:formatter, :runtime, :node) do
        before do
          formatter.before_feature_element(node)
          Legacy::Ast::Tags.new(node.tags).describe_to(formatter)
          formatter.scenario_name node.keyword, node.name, node.location.to_s, indent.of(node)
        end

        def step(step, result)
          @child ||= StepsPrinter.new(formatter).before
          step_result = LegacyResultBuilder.new(result).step_result(step_match(step), background = nil)
          runtime.step_visited step_result
          @child.step step, step_result, runtime, indent
        end

        after do
          formatter.after_feature_element(node)
        end

        private

        def step_match(step)
          runtime.step_match(step.name)
        rescue Cucumber::Undefined
          NoStepMatch.new(step, step.name)
        end

        def step_result(result, background)
          LegacyResultBuilder.new(result).step_result(background)
        end

        def indent
          @indent ||= Indent.new(node)
        end
      end

      StepsPrinter = Printer.new(:formatter) do
        before do
          formatter.before_steps(nil)
        end

        attr_reader :steps
        private :steps

        def step(step, step_result, runtime, indent, background = nil)
          @steps ||= [].extend(Steps)
          steps << Step.new(step, step_result)
          StepPrinter.new(formatter, runtime, indent, step, step_result, background).print
        end

        module Steps
          def failed?
            any?(&:failed?)
          end

          def passed?
            all?(&:passed?)
          end

          def status
            return :passed if passed?
            failed_step.status
          end

          def exception
            failed_step.exception if failed_step
          end

          private
          def failed_step
            detect(&:failed?)
          end
        end

        Step = Struct.new(:step, :step_result) do
          extend Forwardable

          def_delegators :step, :keyword, :name
          def_delegators :step_result, :status, :exception

          def failed?
            status != :passed
          end

          def passed?
            status == :passed
          end
        end

        after do
          formatter.after_steps(steps)
        end

      end

      StepPrinter = Struct.new(:formatter, :runtime, :indent, :step, :step_result, :background) do

        def print
          legacy_step.describe_to(formatter) do
            step_result.describe_to(formatter) do
              print_step_name
              print_multiline_arg
              print_exception
            end
          end
        end

        private

        def print_step_name
          formatter.step_name(step.keyword, step_result.step_match, step_result.status, indent.of(step), background, step.location.to_s)
        end

        def print_multiline_arg
          return unless step.multiline_arg
          MultilineArgPrinter.new(formatter, runtime).print(step.multiline_arg)
        end

        def print_exception
          return unless step_result.exception
          raise step_result.exception if ENV['FAIL_FAST']
          formatter.exception(step_result.exception, step_result.status)
        end

        def legacy_step
          Legacy::Ast::Step.new(step_result, step)
        end

      end

      MultilineArgPrinter = Struct.new(:formatter, :runtime) do
        def print(node)
          formatter.before_multiline_arg node
          node.describe_to(self)
          formatter.after_multiline_arg node
        end

        def step(step, &descend)
          descend.call
        end

        def outline_step(outline_step, &descend)
          descend.call
        end

        def doc_string(doc_string)
          formatter.doc_string(doc_string)
        end

        def table(table)
          table.cells_rows.each do |row|
            TableRowPrinter.new(formatter, runtime, DataTableRow.new(row.map(&:value), row.line)).before.after
          end
        end

        DataTableRow = Struct.new(:values, :line) do
          def dom_id
            "row_#{line}"
          end
        end
      end

      ScenarioOutlinePrinter = Printer.new(:formatter, :runtime, :node) do
        before do
          formatter.before_feature_element(node)
          Legacy::Ast::Tags.new(node.tags).describe_to(formatter)
          formatter.scenario_name node.keyword, node.name, node.location.to_s, indent.of(node)
          OutlineStepsPrinter.new(formatter, runtime, indent).print(node)
        end

        def step(node, result)
          @child.step(node, result)
        end

        def examples_table(examples_table, *)
          @child ||= ExamplesArrayPrinter.new(formatter, runtime).before
          @child.examples_table(examples_table)
        end

        def examples_table_row(node, result)
          @child.examples_table_row(node, result)
        end

        after do
          formatter.after_feature_element(node)
        end

        private

        def indent
          @indent ||= Indent.new(node)
        end
      end

      OutlineStepsPrinter = Struct.new(:formatter, :runtime, :indent, :outline) do
        def print(node)
          node.describe_to self
          steps_printer.after
        end

        def scenario_outline(node, &descend)
          descend.call
        end

        def outline_step(step)
          step_match = NoStepMatch.new(step, step.name)
          step_result = LegacyResultBuilder.new(Core::Test::Result::Skipped.new).
            step_result(step_match, background = nil)
          steps_printer.step step, step_result, runtime, indent, background = nil
        end

        def examples_table(*);end

        private

        def steps_printer
          @steps_printer ||= StepsPrinter.new(formatter).before
        end
      end

      class Indent
        def initialize(node)
          @widths = []
          node.describe_to(self)
        end

        [:background, :scenario, :scenario_outline].each do |node_name|
          define_method(node_name) do |node, &descend|
            record_width_of node
            descend.call
          end
        end

        [:step, :outline_step].each do |node_name|
          define_method(node_name) do |node|
            record_width_of node
          end
        end

        def examples_table(*); end

        def of(node)
          max - node.name.length - node.keyword.length
        end

        private

        def max
          @widths.max
        end

        def record_width_of(node)
          @widths << node.keyword.length + node.name.length + 1
        end
      end

      ExamplesArrayPrinter = Printer.new(:formatter, :runtime) do
        before do
          formatter.before_examples_array(:examples_array)
        end

        def examples_table(examples_table)
          delegate_to ExamplesTablePrinter, examples_table
        end

        def examples_table_row(node, result)
          @child.examples_table_row(node, result)
        end

        def step(node, result)
          @child.step(node, result)
        end

        after do
          formatter.after_examples_array
        end
      end

      ExamplesTablePrinter = Printer.new(:formatter, :runtime, :node) do
        before do
          formatter.before_examples(node)
          formatter.examples_name(node.keyword, node.name)
          formatter.before_outline_table(legacy_table)
          TableRowPrinter.new(formatter, runtime, ExampleTableRow.new(node.header)).before.after
        end

        def examples_table_row(examples_table_row, *)
          delegate_to TableRowPrinter, ExampleTableRow.new(examples_table_row)
        end

        def step(node, result)
          @child.step(node, result)
        end

        class ExampleTableRow < SimpleDelegator
          def dom_id
            file_colon_line.gsub(/[\/\.:]/, '_')
          end
        end

        after do
          formatter.after_outline_table(node)
          formatter.after_examples(node)
        end

        private

        def legacy_table
          LegacyTable.new(node)
        end

        LegacyTable = Struct.new(:node) do
          def col_width(index)
            max_width = FindMaxWidth.new(index)
            node.describe_to max_width
            max_width.result
          end

           require 'gherkin/formatter/escaping'
           FindMaxWidth = Struct.new(:index) do
             include ::Gherkin::Formatter::Escaping

             def examples_table(table, &descend)
               @result = char_length_of(table.header.values[index])
               descend.call
             end

             def examples_table_row(row, &descend)
               width = char_length_of(row.values[index])
               @result = width if width > result
             end

             def result
               @result ||= 0
             end

             private
             def char_length_of(cell)
               escape_cell(cell).unpack('U*').length
             end
           end
        end
      end

      TableRowPrinter = Printer.new(:formatter, :runtime, :node, :background) do
        before do
          formatter.before_table_row(node)
        end

        def step(step, result)
          step_result = LegacyResultBuilder.new(result).step_result(step_match(step))
          runtime.step_visited step_result
          @failed_step_result = step_result if result.failed?
          @status = step_result.status unless @status == :failed
        end

        after do
          node.values.each do |value|
            formatter.before_table_cell(value)
            formatter.table_cell_value(value, @status || :skipped)
            formatter.after_table_cell(value)
          end
          formatter.after_table_row(legacy_table_row)
          if @failed_step_result
            formatter.exception @failed_step_result.exception, @failed_step_result.status
          end
        end

        private

        def step_match(step)
          runtime.step_match(step.name)
        rescue Cucumber::Undefined
          NoStepMatch.new(step, step.name)
        end

        def legacy_table_row
          case node
          when DataTableRow
            LegacyTableRow.new(exception, @status)
          when ExampleTableRow
            LegacyExampleTableRow.new(exception, @status, node.values)
          end
        end

        LegacyTableRow = Struct.new(:exception, :status)
        LegacyExampleTableRow = Struct.new(:exception, :status, :cells) do
          def name
            '| ' + cells.join(' | ') + ' |'
          end

          def failed?
            status == :failed
          end
        end


        def exception
          return nil unless @failed_step_result
          @failed_step_result.exception
        end
      end

      class LegacyResultBuilder
        def initialize(result)
          result.describe_to(self)
        end

        def passed
          @status = :passed
        end

        def failed
          @status = :failed
        end

        def undefined
          @status = :undefined
        end

        def skipped
          @status = :skipped
        end

        def exception(exception, *)
          @exception = exception
        end

        def duration(*); end

        def step_result(step_match, background = nil)
          Legacy::Ast::StepResult.new(:keyword, step_match, :multiline_arg, @status, @exception, :source_indent, background, :file_colon_line)
        end

        def scenario(name, location)
          LegacyScenario.new(@status, name, location)
        end

        def describe_exception_to(formatter)
          formatter.exception(@exception, @status) if @exception
        end

        LegacyScenario = Struct.new(:status, :name, :location)
      end

      # Adapters to pass to the legacy API formatters that provide the interface
      # of the old AST classes
      module Legacy
        module Ast

          Comments = Struct.new(:comments) do

            def describe_to(formatter)
              return if comments.empty?
              formatter.before_comment comments
              comments.each do |comment|
                formatter.comment_line comment.to_s.strip
              end
            end

          end

          StepResult = Struct.new(
            :keyword,
            :step_match,
            :multiline_arg,
            :status,
            :exception,
            :source_indent,
            :background,
            :file_colon_line) do

            def describe_to(formatter)
              formatter.before_step_result *attributes
              yield
              formatter.after_step_result *attributes
            end

            def attributes
              [keyword, step_match, multiline_arg, status, exception, source_indent, background, file_colon_line]
            end
          end

          Step = Struct.new(:step_result, :step) do

            def describe_to(formatter)
              formatter.before_step(self)
              yield
              formatter.after_step(self)
            end

            def status
              step_result.status
            end

            def name
              step.name
            end

            def dom_id

            end

            def multiline_arg

            end

            def actual_keyword
              # TODO: This should return the keyword for the snippet
              # `actual_keyword` translates 'And', 'But', etc. to 'Given', 'When',
              # 'Then' as appropriate
              "Given"
            end
          end

          Tags = Struct.new(:tags) do

            def describe_to(formatter)
              formatter.before_tags tags
              tags.each do |tag|
                formatter.tag_name tag.name
              end
              formatter.after_tags tags
            end

          end

        end
      end

    end
  end
end